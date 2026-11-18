# Diagrams

The hand-drawn diagrams in the READMEs are rendered from the Mermaid sources in [`src/`](src). Each source becomes two SVGs, `<name>.light.svg` and `<name>.dark.svg`. The READMEs embed both in a `<picture>` element, so GitHub shows the one that matches the reader's theme.

## Colours

Every node gets one semantic class, so a colour means the same thing in every diagram. The palette matches the resume site. The colour is on the border only: `build.mjs` strips the diagonal hatching that Mermaid's hand-drawn look puts inside shapes, so they stay plain.

| Class | Colour | Use for |
|---|---|---|
| `gov` | yellow | Management groups, policy, decisions, approval gates |
| `sec` | coral | Firewall, Bastion, gateways, Key Vault, scanning and signing |
| `net` | blue | VNets, clusters, node pools, session hosts, load balancers |
| `data` | teal | Databases, storage, registries, DNS zones, galleries |
| `obs` | purple | Log Analytics, Sentinel, DCE/DCR, AMPLS, Grafana |
| `ci` | amber | GitLab, runners, Flux, pipelines, Image Builder |
| `muted` | grey | Private endpoints, placeholders, external starting points |

Subgraphs take `z-<class>` (for example `class hub z-sec`): paper fill with a dashed border in that colour. The `classDef` lines are added by `build.mjs` for each theme, so the sources only contain `class` assignments.

## Rebuild

Needs Node 20 or later and Chrome or Chromium (set `PUPPETEER_EXECUTABLE_PATH` if it isn't found).

```sh
make diagrams                         # every diagram
cd docs/diagrams && node build.mjs avd-spoke   # just one
PREVIEW=1 node build.mjs              # also write PNG previews and print where they are
```

Commit the regenerated SVGs with the source change. The hand-drawn look uses a fixed seed, so unchanged sources render the same way.

## Font

Text uses Excalifont, Excalidraw's handwriting font, licensed under the [SIL Open Font License 1.1](https://github.com/excalidraw/excalidraw/tree/master/packages/excalidraw/fonts). [`fonts/`](fonts) holds its Latin subset, which is embedded in each SVG so the diagrams render the same everywhere.
