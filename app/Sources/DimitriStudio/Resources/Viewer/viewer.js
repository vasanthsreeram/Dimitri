/*
 * Dimitri Studio structure viewer.
 *
 * A thin layer over the bundled Mol* viewer (molstar.js 5.12.0, MIT, see
 * molstar-LICENSE.txt). The Swift app drives it through window.dimitri and
 * hears back on window.webkit.messageHandlers.dimitri:
 *
 *   {type: 'ready', version}
 *   {type: 'loaded', report, requestId}   what is on screen now
 *   {type: 'error', message, requestId}   a load failed; the canvas is not trusted
 *   {type: 'log', message}                diagnostics only
 *
 * Every load builds its representations explicitly. Mol*'s default preset
 * picks by size and shows small or unclassified structures as ball-and-stick
 * or spacefill atoms, which is how predictions ended up as "dots". Here:
 *
 *   polymer (protein, RNA, DNA)        cartoon, in the requested colour mode
 *   ligands, modified residues, sugars  ball-and-stick
 *   ions                                small spheres
 *   water                               not shown
 */
(function () {
    'use strict';

    // MARK: - Constants

    /** AlphaFold pLDDT bands, highest first. */
    const PLDDT_BANDS = [
        { min: 90, color: 0x0053D6, label: 'Very high (pLDDT ≥ 90)' },
        { min: 70, color: 0x65CBF3, label: 'Confident (70 ≤ pLDDT < 90)' },
        { min: 50, color: 0xFFDB13, label: 'Low (50 ≤ pLDDT < 70)' },
        { min: -Infinity, color: 0xFF7D45, label: 'Very low (pLDDT < 50)' },
    ];
    const PLDDT_THEME = 'dimitri-plddt';
    const NEUTRAL_COLOR = 0x9AA4B2;
    const BACKGROUND = { dark: 0x0D1117, light: 0xFFFFFF };
    const COLOR_MODES = ['plddt', 'chain', 'secondary', 'rainbow', 'uniform'];
    const MOLSTAR_COLOR_THEME = {
        plddt: PLDDT_THEME,
        chain: 'chain-id',
        secondary: 'secondary-structure',
        rainbow: 'sequence-id',
        uniform: 'uniform',
    };
    /** Methods whose B-factors are atomic displacement, not model confidence. */
    const EXPERIMENTAL_METHOD = /X-RAY|NMR|ELECTRON|NEUTRON|FIBER|POWDER|SOLID-STATE|EPR|FLUORESCENCE|INFRARED/i;

    // MARK: - Bridge to Swift

    function post(message) {
        try {
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dimitri;
            if (handler) {
                handler.postMessage(message);
            } else {
                console.log('[dimitri]', message);
            }
        } catch (error) {
            console.error('[dimitri] could not post message', error);
        }
    }

    function log(message) {
        post({ type: 'log', message: String(message) });
    }

    function describeError(error) {
        if (!error) return 'Unknown error';
        if (typeof error === 'string') return error;
        return error.message || String(error);
    }

    // Uncaught errors are logged, not reported as load failures: Mol* and
    // WebKit raise some harmless ones (e.g. ResizeObserver loop warnings).
    window.addEventListener('error', (event) => {
        log(`Uncaught: ${event.message || describeError(event.error)}`);
    });
    window.addEventListener('unhandledrejection', (event) => {
        log(`Unhandled rejection: ${describeError(event.reason)}`);
    });
    document.addEventListener('securitypolicyviolation', (event) => {
        log(`Blocked by content security policy: ${event.blockedURI} (${event.violatedDirective})`);
    });

    // MARK: - State

    let plugin = null;
    let lib = null;
    let theme = initialTheme();
    /** One entry per structure on screen. */
    let entries = [];
    let lastReport = null;
    let lastRequestId = null;
    let loadCounter = 0;
    let queue = Promise.resolve();
    /** Resolves once Mol* is up; every command waits for it. Set at the end of this file. */
    let started = null;

    /** Runs viewer operations one at a time, in call order. */
    function enqueue(task) {
        const run = queue.then(task, task);
        queue = run.catch(() => undefined);
        return run;
    }

    // MARK: - Start-up

    async function start() {
        applyPageTheme(theme);
        guardFileDrops();
        try {
            if (!window.molstar || !window.molstar.Viewer || !window.molstar.lib) {
                throw new Error('molstar.js did not load.');
            }
            lib = window.molstar.lib;
            const PluginConfig = lib.plugin.PluginConfig;
            const viewer = await window.molstar.Viewer.create(document.getElementById('app'), {
                // No extensions: several of them reach out to web services.
                extensions: [],
                layoutIsExpanded: false,
                layoutShowControls: false,
                layoutShowRemoteState: false,
                layoutShowSequence: false,
                layoutShowLog: false,
                layoutShowLeftPanel: false,
                collapseLeftPanel: true,
                collapseRightPanel: true,
                viewportShowReset: false,
                viewportShowScreenshotControls: false,
                viewportShowControls: false,
                viewportShowExpand: false,
                viewportShowToggleFullscreen: false,
                viewportShowSettings: false,
                viewportShowSelectionMode: false,
                viewportShowAnimation: false,
                viewportShowTrajectoryControls: false,
                volumeStreamingDisabled: true,
                powerPreference: 'default',
                illumination: false,
                config: [
                    [PluginConfig.Viewport.ShowXR, 'never'],
                    [PluginConfig.Viewport.ShowIllumination, false],
                ],
            });
            plugin = viewer.plugin;
            if (!plugin.canvas3d) {
                throw new Error('WebGL is not available, so the 3D view cannot be drawn.');
            }
            plugin.representation.structure.themes.colorThemeRegistry.add(PlddtColorThemeProvider);
            applyCanvasTheme(theme);
            watchGraphicsContext();
            post({ type: 'ready', version: window.molstar.version || null });
        } catch (error) {
            post({ type: 'error', message: `The structure viewer could not start: ${describeError(error)}`, requestId: null });
            throw error;
        }
    }

    function initialTheme() {
        const requested = new URLSearchParams(window.location.search).get('theme');
        if (requested === 'light' || requested === 'dark') return requested;
        return window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    }

    /** Mol* loads files dropped on its canvas; in the app that would replace the job's structure. */
    function guardFileDrops() {
        for (const type of ['dragenter', 'dragover', 'drop']) {
            window.addEventListener(type, (event) => {
                event.preventDefault();
                event.stopPropagation();
            }, true);
        }
    }

    function watchGraphicsContext() {
        const canvas = document.querySelector('#app canvas');
        if (!canvas) return;
        canvas.addEventListener('webglcontextlost', () => {
            post({ type: 'error', message: 'The 3D view lost its graphics context.', requestId: lastRequestId });
        });
        canvas.addEventListener('webglcontextrestored', () => {
            log('Graphics context restored.');
            if (lastReport) post({ type: 'loaded', report: lastReport, requestId: lastRequestId });
        });
    }

    // MARK: - pLDDT colour theme

    /** Scale per model: B-factors that never exceed 1 are pLDDT / 100. */
    const scaleCache = new WeakMap();

    function bFactorRange(model) {
        const column = model.atomicConformation.B_iso_or_equiv;
        let min = Infinity;
        let max = -Infinity;
        const count = column.rowCount;
        for (let i = 0; i < count; i++) {
            const value = column.value(i);
            if (value < min) min = value;
            if (value > max) max = value;
        }
        return { defined: column.isDefined && count > 0, min, max };
    }

    function confidenceScale(model) {
        let scale = scaleCache.get(model);
        if (scale === undefined) {
            scale = bFactorRange(model).max <= 1 ? 100 : 1;
            scaleCache.set(model, scale);
        }
        return scale;
    }

    function bandColor(plddt) {
        for (const band of PLDDT_BANDS) {
            if (plddt >= band.min) return band.color;
        }
        return NEUTRAL_COLOR;
    }

    function plddtColorTheme(ctx, props) {
        const { StructureElement, Bond, Unit } = lib.structure;

        function atomColor(unit, element) {
            if (!Unit.isAtomic(unit)) return NEUTRAL_COLOR;
            const value = unit.model.atomicConformation.B_iso_or_equiv.value(element);
            return bandColor(value * confidenceScale(unit.model));
        }

        return {
            factory: plddtColorTheme,
            granularity: 'group',
            preferSmoothing: false,
            color(location) {
                if (StructureElement.Location.is(location)) {
                    return atomColor(location.unit, location.element);
                }
                if (Bond.isLocation(location)) {
                    return atomColor(location.aUnit, location.aUnit.elements[location.aIndex]);
                }
                return NEUTRAL_COLOR;
            },
            props,
            description: 'Model confidence (pLDDT) read from per-atom B-factors, in the AlphaFold bands.',
            legend: { kind: 'table-legend', table: PLDDT_BANDS.map((band) => [band.label, band.color]) },
        };
    }

    const PlddtColorThemeProvider = {
        name: PLDDT_THEME,
        label: 'pLDDT (B-factor)',
        category: 'Validation',
        factory: plddtColorTheme,
        getParams: () => ({}),
        defaultValues: {},
        isApplicable: (ctx) => !!ctx.structure,
    };

    // MARK: - Reading the input

    /** Trusts the text over the declared format: mmCIF starts with `data_`, PDB with record names. */
    function detectFormat(text, declared) {
        const head = text.slice(0, 16384);
        for (const raw of head.split(/\r?\n/)) {
            const line = raw.trim();
            if (!line || line.startsWith('#')) continue;
            if (/^data_/i.test(line)) return 'mmcif';
            // Record names are followed by a space, a digit (SCALE1, serials) or the line end.
            if (/^(HEADER|OBSLTE|TITLE|SPLIT|CAVEAT|COMPND|SOURCE|KEYWDS|EXPDTA|NUMMDL|MDLTYP|AUTHOR|REVDAT|SPRSDE|JRNL|REMARK|DBREF|SEQADV|SEQRES|MODRES|HET|HETNAM|HETSYN|FORMUL|HELIX|SHEET|SSBOND|LINK|CISPEP|SITE|CRYST1|ORIGX|SCALE|MTRIX|MODEL|ATOM|HETATM|ANISOU|TER|ENDMDL|CONECT|MASTER|END)(?=[\s\d]|$)/.test(raw)) {
                return 'pdb';
            }
            break;
        }
        if (/^_atom_site\./m.test(head) || /^loop_\s*$/m.test(head)) return 'mmcif';
        return declared === 'pdb' ? 'pdb' : 'mmcif';
    }

    /** The experimental method named in the file, if any. */
    function experimentalMethod(text, format) {
        const head = text.slice(0, 262144);
        let method = null;
        if (format === 'pdb') {
            const match = /^EXPDTA\s+(.+)$/m.exec(head);
            if (match) method = match[1].trim();
        } else {
            const at = head.indexOf('_exptl.method');
            if (at >= 0) {
                const match = EXPERIMENTAL_METHOD.exec(head.slice(at, at + 400));
                if (match) method = match[0];
            }
        }
        return method && EXPERIMENTAL_METHOD.test(method) ? method : null;
    }

    function formatNumber(value) {
        return Number.isInteger(value) ? String(value) : value.toFixed(2);
    }

    /** Whether the B-factors can honestly be shown as pLDDT. */
    function confidenceOf(model, text, format) {
        const method = experimentalMethod(text, format);
        if (method) {
            return { hasConfidence: false, note: `Experimental structure (${method}); its B-factors are not pLDDT.` };
        }
        const range = bFactorRange(model);
        if (!range.defined) {
            return { hasConfidence: false, note: 'The file has no B-factor column.' };
        }
        if (range.max - range.min < 1e-6) {
            return {
                hasConfidence: false,
                note: `Every B-factor is ${formatNumber(range.max)}, so the file carries no per-residue confidence.`,
            };
        }
        if (range.min < 0 || range.max > 100) {
            return {
                hasConfidence: false,
                note: `B-factors run from ${formatNumber(range.min)} to ${formatNumber(range.max)}, outside the pLDDT range.`,
            };
        }
        const scale = range.max <= 1 ? 100 : 1;
        return {
            hasConfidence: true,
            scale,
            min: range.min * scale,
            max: range.max * scale,
            note: scale === 100 ? 'B-factors are on a 0–1 scale and were multiplied by 100.' : null,
        };
    }

    function normalise(structures, options) {
        if (!Array.isArray(structures)) throw new Error('load() expects an array of structures.');
        const fallbackColor = options && COLOR_MODES.includes(options.color) ? options.color : 'plddt';
        return structures.map((item, index) => {
            if (!item || typeof item.text !== 'string' || !item.text.trim()) {
                throw new Error(`Structure ${index + 1} has no text.`);
            }
            const id = item.id !== undefined && item.id !== null ? String(item.id) : `structure-${index + 1}`;
            return {
                id,
                text: item.text,
                declaredFormat: item.format === 'pdb' || item.format === 'mmcif' ? item.format : null,
                label: item.label ? String(item.label) : id,
                color: COLOR_MODES.includes(item.color) ? item.color : fallbackColor,
                uniformColor: item.uniformColor || null,
            };
        });
    }

    // MARK: - Inspecting what Mol* built

    function polymerKind(type) {
        const PolymerType = lib.structure.Types.PolymerType;
        switch (type) {
            case PolymerType.Protein:
            case PolymerType.GammaProtein:
            case PolymerType.BetaProtein:
                return 'protein';
            case PolymerType.RNA: return 'rna';
            case PolymerType.DNA: return 'dna';
            case PolymerType.PNA: return 'pna';
            default: return null;
        }
    }

    /** Atoms, residues, chains and bonds of a structure. */
    function countStructure(structure) {
        const { StructureElement, StructureProperties: P, Unit } = lib.structure;
        const location = StructureElement.Location.create(structure);
        const residues = new Set();
        const chains = new Set();
        let bonds = structure.interUnitBonds ? structure.interUnitBonds.edgeCount : 0;
        for (const unit of structure.units) {
            if (!Unit.isAtomic(unit)) continue;
            bonds += unit.bonds.edgeCount;
            location.unit = unit;
            const elements = unit.elements;
            for (let i = 0; i < elements.length; i++) {
                location.element = elements[i];
                residues.add(P.residue.key(location));
                chains.add(P.chain.key(location));
            }
        }
        return { atoms: structure.elementCount, residues: residues.size, chains: chains.size, bonds };
    }

    /** Polymer kinds and size; `traceOnly` means CA-only or P-only coordinates. */
    function describePolymer(polymer) {
        const { StructureElement, StructureProperties: P, Unit } = lib.structure;
        const location = StructureElement.Location.create(polymer);
        const kinds = new Set();
        const residues = new Set();
        let atoms = 0;
        for (const unit of polymer.units) {
            if (!Unit.isAtomic(unit)) continue;
            const polymerType = unit.model.atomicHierarchy.derived.residue.polymerType;
            location.unit = unit;
            const elements = unit.elements;
            for (let i = 0; i < elements.length; i++) {
                location.element = elements[i];
                atoms += 1;
                const residue = P.residue.key(location);
                if (residues.has(residue)) continue;
                residues.add(residue);
                const kind = polymerKind(polymerType[residue]);
                if (kind) kinds.add(kind);
            }
        }
        return {
            kinds: Array.from(kinds).sort(),
            residues: residues.size,
            traceOnly: residues.size > 0 && atoms / residues.size < 3,
        };
    }

    /** Residues in helices and strands, read after the cartoon attached secondary structure. */
    function secondaryStructure(root, polymer) {
        const { StructureElement, StructureProperties: P, Unit, Types } = lib.structure;
        const Flag = Types.SecondaryStructureType.Flag;
        const location = StructureElement.Location.create(root);
        const seen = new Set();
        let helix = 0;
        let sheet = 0;
        try {
            for (const unit of polymer.units) {
                if (!Unit.isAtomic(unit)) continue;
                location.unit = unit;
                const elements = unit.elements;
                for (let i = 0; i < elements.length; i++) {
                    location.element = elements[i];
                    const residue = P.residue.key(location);
                    if (seen.has(residue)) continue;
                    seen.add(residue);
                    const type = P.residue.secondary_structure_type(location);
                    if (type & Flag.Helix) helix += 1;
                    else if (type & Flag.Beta) sheet += 1;
                }
            }
        } catch (error) {
            log(`Secondary structure unavailable: ${describeError(error)}`);
            return null;
        }
        return { helix, sheet };
    }

    // MARK: - Colour

    function parseHexColor(value) {
        const match = /^#?([0-9a-f]{6})$/i.exec(value || '');
        return match ? parseInt(match[1], 16) : null;
    }

    /** The colour mode actually used: pLDDT falls back when the file has no confidence. */
    function resolveColor(requested, entry) {
        let mode = COLOR_MODES.includes(requested) ? requested : 'plddt';
        if (mode === 'plddt' && !entry.confidence.hasConfidence) {
            mode = entry.polymer.kinds.includes('protein') ? 'secondary' : 'chain';
        }
        const params = mode === 'uniform' ? { value: parseHexColor(entry.uniformColor) ?? NEUTRAL_COLOR } : {};
        return { mode, theme: MOLSTAR_COLOR_THEME[mode], params };
    }

    async function recolor(entry, color) {
        const ref = entry.polymerComponent.ref;
        for (const structure of plugin.managers.structure.hierarchy.current.structures) {
            for (const component of structure.components) {
                if (component.cell.transform.ref === ref) {
                    await plugin.managers.structure.component.updateRepresentationsTheme([component], {
                        color: color.theme,
                        colorParams: color.params,
                    });
                    return;
                }
            }
        }
        throw new Error(`Could not find the cartoon for ${entry.label}.`);
    }

    // MARK: - Loading

    async function loadStructure(input) {
        const builders = plugin.builders;
        const format = detectFormat(input.text, input.declaredFormat);
        const warnings = [];
        if (input.declaredFormat && input.declaredFormat !== format) {
            warnings.push(`Declared ${input.declaredFormat} but the text is ${format}; read it as ${format}.`);
        }

        let trajectory;
        try {
            const data = await builders.data.rawData({ data: input.text, label: input.label });
            trajectory = await builders.structure.parseTrajectory(data, format);
        } catch (error) {
            throw new Error(`Could not read ${input.label} as ${format === 'pdb' ? 'PDB' : 'mmCIF'}: ${describeError(error)}`);
        }
        const models = trajectory.data ? trajectory.data.frameCount : 1;
        if (!models) throw new Error(`${input.label} contains no models.`);
        if (models > 1) warnings.push(`The file has ${models} models; showing the first.`);

        // First model only, as the deposited/predicted asymmetric unit.
        const model = await builders.structure.createModel(trajectory, { modelIndex: 0 });
        const structureRef = await builders.structure.createStructure(model, { name: 'model', params: {} });
        const structure = structureRef.data;
        if (!structure || structure.elementCount === 0) throw new Error(`${input.label} has no atoms.`);

        const make = (type) => builders.structure.tryCreateComponentStatic(structureRef, type);
        const components = {
            polymer: await make('polymer'),
            ligand: await make('ligand'),
            nonStandard: await make('non-standard'),
            branched: await make('branched'),
            lipid: await make('lipid'),
            ion: await make('ion'),
            coarse: await make('coarse'),
            // Water is never created, so it is never drawn.
        };

        const entry = {
            id: input.id,
            label: input.label,
            uniformColor: input.uniformColor,
            requestedColor: input.color,
            polymerComponent: components.polymer || null,
            confidence: confidenceOf(structure.models[0], input.text, format),
            polymer: components.polymer
                ? describePolymer(components.polymer.data)
                : { kinds: [], residues: 0, traceOnly: false },
            report: null,
        };
        if (!components.polymer) {
            warnings.push('No polymer chain was recognised, so there is no cartoon; atoms are drawn individually.');
        } else if (entry.polymer.traceOnly) {
            warnings.push('Only trace atoms (CA or P) are present; the cartoon follows the trace.');
        }

        const color = resolveColor(input.color, entry);
        const add = (component, props, tag) => plugin.builders.structure.representation.addRepresentation(component, props, { tag });
        const representations = [];
        if (components.polymer) {
            await add(components.polymer, { type: 'cartoon', color: color.theme, colorParams: color.params }, 'dimitri-polymer');
            representations.push('cartoon');
        }
        for (const key of ['ligand', 'nonStandard', 'branched', 'lipid']) {
            if (!components[key]) continue;
            await add(components[key], { type: 'ball-and-stick', color: 'element-symbol' }, `dimitri-${key}`);
            representations.push('ball-and-stick');
        }
        if (components.ion) {
            await add(components.ion, { type: 'ball-and-stick', typeParams: { sizeFactor: 0.35 }, color: 'element-symbol' }, 'dimitri-ion');
            representations.push('spheres');
        }
        if (components.coarse) {
            await add(components.coarse, { type: 'spacefill', color: 'chain-id' }, 'dimitri-coarse');
            representations.push('spacefill');
        }

        const counts = countStructure(structure);
        entry.report = {
            id: entry.id,
            label: entry.label,
            format,
            models,
            atoms: counts.atoms,
            residues: counts.residues,
            chains: counts.chains,
            bonds: counts.bonds,
            polymerTypes: entry.polymer.kinds,
            polymerResidues: entry.polymer.residues,
            traceOnly: entry.polymer.traceOnly,
            secondaryStructure: components.polymer ? secondaryStructure(structure, components.polymer.data) : null,
            hasConfidence: entry.confidence.hasConfidence,
            confidenceNote: entry.confidence.note || null,
            plddtRange: entry.confidence.hasConfidence ? [entry.confidence.min, entry.confidence.max] : null,
            // Colour modes apply to the cartoon; without one, atoms are coloured by element.
            color: components.polymer ? color.mode : 'element',
            representation: Array.from(new Set(representations)).join('+') || 'none',
            warnings,
        };
        return entry;
    }

    function nextFrames() {
        return new Promise((resolve) => {
            let done = false;
            const finish = () => {
                if (done) return;
                done = true;
                resolve();
            };
            requestAnimationFrame(() => requestAnimationFrame(finish));
            setTimeout(finish, 500);
        });
    }

    /**
     * Fits everything on screen, then turns the view so the structures'
     * principal axes line up with the screen (long axis across): a straight
     * helix or a long RNA is seen side-on rather than end-on. The turn waits
     * until Mol* has applied the fit, which happens on its next frame.
     */
    function frameCamera(durationMs) {
        return new Promise((resolve) => {
            let done = false;
            const finish = () => {
                if (done) return;
                done = true;
                resolve();
            };
            plugin.canvas3d.requestCameraReset({
                durationMs: 0,
                snapshot: () => {
                    setTimeout(() => {
                        plugin.managers.camera.orientAxes(undefined, durationMs);
                        finish();
                    }, 0);
                    return undefined;
                },
            });
            setTimeout(finish, 1500);
        });
    }

    function load(structures, options) {
        const token = ++loadCounter;
        const requestId = options && options.requestId !== undefined ? options.requestId : null;
        return enqueue(async () => {
            const startedAt = performance.now();
            try {
                await started;
                if (token !== loadCounter) return { superseded: true };
                if (options && options.theme) applyTheme(options.theme);
                const inputs = normalise(structures, options);

                await plugin.clear();
                entries = [];
                lastReport = null;
                lastRequestId = requestId;
                for (const input of inputs) {
                    if (token !== loadCounter) return { superseded: true };
                    entries.push(await loadStructure(input));
                }
                if (entries.length > 0 && entries.every((entry) => entry.report.representation === 'none')) {
                    throw new Error('Nothing to draw: the file has no polymer, ligand or ion atoms.');
                }

                plugin.canvas3d.commit(true);
                await frameCamera(0);
                await nextFrames();

                const report = { structures: entries.map((entry) => entry.report), ms: Math.round(performance.now() - startedAt) };
                lastReport = report;
                post({ type: 'loaded', report, requestId });
                return report;
            } catch (error) {
                const message = describeError(error);
                post({ type: 'error', message, requestId });
                return { error: message };
            }
        });
    }

    // MARK: - Other commands

    /** Recolours the cartoon of one structure (`id`) or of all of them; no reload. */
    function setColor(mode, id, uniformColor) {
        return enqueue(async () => {
            await started;
            if (!COLOR_MODES.includes(mode)) throw new Error(`Unknown colour mode '${mode}'.`);
            for (const entry of entries) {
                if (id !== undefined && id !== null && entry.id !== String(id)) continue;
                entry.requestedColor = mode;
                if (uniformColor !== undefined) entry.uniformColor = uniformColor;
                const color = resolveColor(mode, entry);
                if (entry.polymerComponent) await recolor(entry, color);
                entry.report.color = entry.polymerComponent ? color.mode : 'element';
            }
            if (lastReport) {
                lastReport = { ...lastReport, structures: entries.map((entry) => entry.report) };
                post({ type: 'loaded', report: lastReport, requestId: lastRequestId });
            }
            return lastReport;
        });
    }

    function applyPageTheme(name) {
        document.documentElement.dataset.theme = name;
    }

    function applyCanvasTheme(name) {
        if (plugin && plugin.canvas3d) {
            plugin.canvas3d.setProps({
                renderer: { backgroundColor: BACKGROUND[name] },
                camera: { helper: { axes: { name: 'off', params: {} } } },
            });
        }
    }

    function applyTheme(name) {
        theme = name === 'light' ? 'light' : 'dark';
        applyPageTheme(theme);
        applyCanvasTheme(theme);
    }

    async function setTheme(name) {
        await started;
        applyTheme(name);
        return theme;
    }

    async function resetView() {
        await started;
        await frameCamera(250);
    }

    /** PNG data URL of the current view, rendered by Mol* at the viewport size or `width`×`height`. */
    function snapshot(options) {
        return enqueue(async () => {
            await started;
            const helper = plugin.helpers.viewportScreenshot;
            if (!helper) throw new Error('Snapshots need a WebGL canvas.');
            const width = options && Number(options.width);
            const height = options && Number(options.height);
            const resolution = width > 0 && height > 0
                ? { name: 'custom', params: { width: Math.round(width), height: Math.round(height) } }
                : { name: 'viewport', params: {} };
            helper.behaviors.values.next({
                ...helper.values,
                resolution,
                format: { name: 'png', params: {} },
                transparent: false,
                axes: { name: 'off', params: {} },
            });
            return helper.getImageDataUri();
        });
    }

    function clear() {
        loadCounter += 1;
        return enqueue(async () => {
            await started;
            await plugin.clear();
            entries = [];
            lastReport = null;
        });
    }

    /** For the offline check: Mol* version, WebGL, and the scripts and styles the page uses. */
    async function diagnostics() {
        await started;
        const gl = plugin.canvas3d.webgl;
        return {
            version: window.molstar.version || null,
            webgl2: !!(gl && gl.isWebGL2),
            theme,
            resources: [
                ...Array.from(document.scripts, (script) => script.src).filter(Boolean),
                ...Array.from(document.querySelectorAll('link[rel="stylesheet"]'), (link) => link.href),
            ],
            page: window.location.href,
        };
    }

    started = start();
    started.catch(() => undefined); // reported to Swift by start() itself
    window.dimitri = Object.freeze({ load, setColor, setTheme, resetView, snapshot, clear, diagnostics });
})();
