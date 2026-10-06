# Disable cart for embargoed genomes

## Context

Users can add genes from embargoed genomes to their cart via gene pages, keyword search, and BLAST results. Cart downloads then fail for these items. The download button on info pages already hides for embargoed genomes, but the cart pathway has no such check.

`dataPolicy` (values: `"unrestricted"`, `"restricted"`, `"embargoed"`) lives on each organism in `njphytozome.json`, parsed at startup into the Redux `targets` store (`state.targets.organisms[i].attributes.dataPolicy`). This store is globally available.

## Approach

Two changes:

### 1. Central gate in `SaveCheckedToCartButton`

**File:** `src/components/cart/buttons-and-dialogs/save-checked-to-cart.jsx`

Add a new prop `embargoedMessage` (string, optional). When truthy, the button is disabled and the tooltip shows this message instead of the login prompt. Each call site sets this prop when the context is an embargoed genome.

Current disable logic (line 107-109):
```js
const disabled = ( checkedQuantity == 0 || !userAuth.isLoggedIn ) ? true : false
```

New logic:
```js
const disabled = ( checkedQuantity == 0 || !userAuth.isLoggedIn || embargoedMessage ) ? true : false
```

Tooltip priority: `embargoedMessage` > login message > none.

Message text: *"This genome is embargoed. Data use is limited."*

For ag-Grid tables (keyword search, BLAST), also add a row-level tooltip on embargoed rows via `tooltipValueGetter` so hovering anywhere on a greyed-out row explains why selection is disabled.

### 2. Each call site passes the embargo check

#### A. Gene report topmatter
**File:** `src/components/gene-report/topmatter.jsx`

The parent gene route (`src/routes/gene/index.jsx`, line 24) already resolves the proteome object from `targets.organisms`. It knows `dataPolicy`. Pass it down through `GeneReport` → `TopMatter` as a prop (e.g., `dataPolicy`). In `TopMatter`, set `embargoedMessage` on `SaveCheckedToCartButton` when `dataPolicy === 'embargoed'`.

#### B. Gene report proteinHomologs and HMMs
**Files:** `src/components/gene-report/proteinHomologs.jsx`, `src/components/gene-report/hmms.jsx`

Same approach — pass `dataPolicy` from the gene route through `GeneReport` into these sub-components. They already receive `geneResults` via context/props; adding one more prop is straightforward.

#### C. Keyword search results
**File:** `src/components/keyword-results/index.jsx`

Already has `props.targets` with `organisms` and `organismsIndex`. The search can span multiple organisms, some embargoed and some not. Two sub-changes:

- **Cart button:** If ALL selected proteomes in the search are embargoed, disable the button with `embargoedMessage`. If mixed, allow the button (or filter at selection time).
- **Checkboxes:** Use ag-Grid's `isRowSelectable` callback to prevent checking rows from embargoed organisms. The row data includes the proteome id (from `r._source.organism.proteome` at line 72). Look up `dataPolicy` via `organismsIndex` and return false for embargoed rows.

#### D. BLAST results table
**Files:** `src/routes/blast-results/index.jsx`, `src/components/blast-viewer/index.jsx`, `src/components/blast-viewer/results-table/index.jsx`

Thread `targets` from the blast route (already in Redux at line 225) → `BlastViewer` → `TableBlast`. BLAST runs against a single organism context, so if that organism is embargoed, disable (grey out) the cart button and grey out the checkboxes. The organism's proteome ID is available in the blast job metadata.

## Files to modify

1. `src/components/cart/buttons-and-dialogs/save-checked-to-cart.jsx` — add `embargoedMessage` prop to disable logic and tooltip
2. `src/routes/gene/index.jsx` — resolve and pass `dataPolicy` to GeneReport
3. `src/components/gene-report/index.jsx` — pass `dataPolicy` to TopMatter, proteinHomologs, hmms
4. `src/components/gene-report/topmatter.jsx` — pass `embargoedMessage` to SaveCheckedToCartButton
5. `src/components/gene-report/proteinHomologs.jsx` — same
6. `src/components/gene-report/hmms.jsx` — same
7. `src/components/keyword-results/index.jsx` — add `isRowSelectable` check, set `embargoedMessage` on cart button
8. `src/routes/blast-results/index.jsx` — pass `targets` to BlastViewer
9. `src/components/blast-viewer/index.jsx` — pass `targets` to TableBlast
10. `src/components/blast-viewer/results-table/index.jsx` — check embargo, conditionally hide checkbox column and cart button

## Verification

- Find an embargoed proteome in `njphytozome.json` (e.g., search for `"dataPolicy": "embargoed"`)
- `npm start` and navigate to a gene page for that proteome — "Add to Cart" should be disabled with tooltip
- Search keywords against that proteome — checkboxes should be unselectable, cart button disabled
- Run a blastp against that proteome — checkboxes greyed out, cart button greyed out
- Verify unrestricted/restricted proteomes still work normally
