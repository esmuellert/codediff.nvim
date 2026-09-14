# Refresh Strategy

## Session-data refactor (#558)

Repository watching, polling, invalidation coalescing and stale-result checks now
belong to `lua/codediff/ui/refresh/init.lua`. Explorer, History and diff views
consume data changes rather than managing independent refresh loops.

- `session.panel.data` owns list data, query parameters and the selected file.
  Panel views hold a reference to that data and receive `on_data(data, changes)`
  notifications. They retain tree expansion, cursor and layout state locally.
- `refresh/panel.lua` reads status, commit lists and commit files, and derives
  comparison definitions from selections. User selection goes through
  `refresh.select`; a list update never asks the view to reselect an unchanged
  comparison.
- `refresh/inputs.lua` reads the session's explicit input definitions, waits for
  every candidate and validates working-buffer ticks. It does not inspect panels.
- The controller publishes only actual input changes to `view/render.lua`.
  Initial rendering and in-place updates share diff rendering; merge input and
  Result rendering remain in `conflict/view/`. Working and Result buffers stay
  authoritative for user edits.

Removed the `auto_refresh` entry point, Explorer scheduler and per-panel refresh
modules. The former `refresh/apply.lua` responsibilities now live in the existing
view helpers and renderers; there is no separate refresh rendering pipeline.
Watcher categories remain intact, with a 500 ms polling fallback. Poll ticks
sample only when no selection, read or invalidation is pending; slow Git reads
must finish rather than accumulate an endless polling backlog. Actual repository
invalidations are still queued while a read is running. Unchanged inputs do not
disturb the comparison, and changed merge inputs cannot overwrite an edited Result.

Regression coverage includes native watcher and polling screen-grid E2Es, data
ownership, presentation-only list updates, navigation, hunk actions and stale
callbacks. The investigation below records the earlier VSCode design reference.

## Earlier investigation: VSCode Quick Diff
VSCode uses a sophisticated system called "Quick Diff" (also known as "Dirty Diff") to display real-time diff decorations in the gutter and overview ruler. The implementation is found primarily in two files:
- `quickDiffModel.ts` - Manages diff computation and change tracking
- `quickDiffDecorator.ts` - Handles visual decorations in the editor

## Key Components

### 1. QuickDiffModel (Core Diff Logic)
Location: `src/vs/workbench/contrib/scm/browser/quickDiffModel.ts`

**Responsibilities:**
- Computes diffs between current buffer and original content
- Manages multiple diff providers (Git HEAD, staged changes, etc.)
- Caches and updates diff results

### 2. QuickDiffDecorator (Visual Layer)
Location: `src/vs/workbench/contrib/scm/browser/quickDiffDecorator.ts`

**Responsibilities:**
- Listens to QuickDiffModel changes
- Updates editor decorations (gutter, overview ruler, minimap)
- Manages decoration lifecycle per editor

## Diff Refresh Triggers

### When does VSCode trigger diff computation?

1. **Text Content Changes**
   ```typescript
   this._register(textFileModel.textEditorModel.onDidChangeContent(() => this.triggerDiff()));
   ```
   - Triggers on ANY content change in the buffer
   - Uses a throttled delayer (200ms default)

2. **Configuration Changes**
   ```typescript
   this._register(
       Event.filter(configurationService.onDidChangeConfiguration,
           e => e.affectsConfiguration('scm.diffDecorationsIgnoreTrimWhitespace') || 
                e.affectsConfiguration('diffEditor.ignoreTrimWhitespace')
       )(this.triggerDiff, this)
   );
   ```
   - Triggers when diff-related settings change

3. **SCM Repository Changes**
   ```typescript
   disposables.add(repository.provider.onDidChangeResources(this.triggerDiff, this));
   ```
   - Triggers when Git repository status changes (commits, checkouts, etc.)

4. **Original Content Changes**
   ```typescript
   this._originalEditorModelsDisposables.add(
       ref.object.textEditorModel.onDidChangeContent(() => this.triggerDiff())
   );
   ```
   - Triggers when the "original" (e.g., HEAD version) changes

5. **Encoding Changes**
   ```typescript
   this._register(this._model.onDidChangeEncoding(() => {
       this._diffDelayer.cancel();
       this._quickDiffs = [];
       this.setChanges([], [], new Map());
       this.triggerDiff();
   }));
   ```

6. **Quick Diff Provider Changes**
   ```typescript
   this._register(this.quickDiffService.onDidChangeQuickDiffProviders(() => this.triggerDiff()));
   ```

## Throttling Strategy

### ThrottledDelayer (200ms)
```typescript
private _diffDelayer = this._register(new ThrottledDelayer<void>(200));
```

**How it works:**
- Batches rapid consecutive changes within 200ms window
- Only runs diff ONCE after the last change in the window
- Prevents performance issues from typing/rapid edits
- Cancellable if model is disposed or encoding changes

**Example:**
```
User types: "hello world" (11 keystrokes in 1 second)
Without throttling: 11 diff computations
With 200ms throttling: 1 diff computation (after last keystroke + 200ms)
```

## Diff Computation Strategy

### Does VSCode rerun the algorithm or use patches?

**Answer: VSCode RERUNS the full diff algorithm each time**

```typescript
private async _diff(original: URI, modified: URI, ignoreTrimWhitespace: boolean) {
    const result = await this.editorWorkerService.computeDiff(original, modified, {
        computeMoves: false, 
        ignoreTrimWhitespace, 
        maxComputationTimeMs
    }, this.options.algorithm);
    
    return { 
        changes: result ? toLineChanges(DiffState.fromDiffResult(result)) : null, 
        changes2: result?.changes ?? null 
    };
}
```

**Key Points:**
1. **Full recomputation** - No incremental patching
2. **Worker thread** - Uses `editorWorkerService` to avoid blocking UI
3. **Algorithm choice** - Uses 'advanced' algorithm by default
4. **Timeout protection** - `maxComputationTimeMs: 1000` (1 second max)
5. **Large file protection** - Checks `canComputeDirtyDiff()` before running

### Why full recomputation?
- Simpler implementation
- More accurate results
- Worker thread makes it non-blocking
- Throttling reduces frequency
- Timeout prevents hanging on large files

## Decoration Update Strategy

### How are decorations refreshed?

The `QuickDiffDecorator` listens to model changes:

```typescript
this._register(Event.runAndSubscribe(
    this.quickDiffModelRef.object.onDidChange, 
    () => this.onDidChange()
));
```

**On each change:**
1. **Clear old decorations** (or reuse collection)
2. **Build new decoration array** from current changes
3. **Update in one atomic operation**

```typescript
private onDidChange(): void {
    const decorations: IModelDeltaDecoration[] = [];
    
    // Build decorations from current changes
    for (const change of this.quickDiffModelRef.object.changes) {
        // ... create decoration for each change ...
        decorations.push({
            range: { ... },
            options: this.addedOptions / this.modifiedOptions / this.deletedOptions
        });
    }
    
    // Atomic update
    if (!this.decorationsCollection) {
        this.decorationsCollection = this.codeEditor.createDecorationsCollection(decorations);
    } else {
        this.decorationsCollection.set(decorations);  // Replaces all at once
    }
}
```

**Benefits:**
- Atomic updates prevent flickering
- Efficient batch update API
- Decorations are immutable (recreated each time)

## Progress Indication

VSCode shows progress for long-running diffs:

```typescript
return this.progressService.withProgress(
    { location: ProgressLocation.Scm, delay: 250 }, 
    async () => { /* diff computation */ }
);
```

- Shows in SCM view after 250ms
- User knows something is happening for large files

## Multi-Provider Support

VSCode supports multiple diff providers simultaneously:
- **Primary** (e.g., Git HEAD)
- **Secondary** (e.g., Git staged/index)
- **Contributed** (extension-provided)

**Overlap handling:**
```typescript
if (quickDiff.kind !== 'primary' && 
    primaryQuickDiffChanges.some(c => c.change2.modified.intersectsOrTouches(change.change2.modified))) {
    continue; // Skip overlapping secondary changes
}
```

## Performance Optimizations

1. **Throttling (200ms)** - Reduces computation frequency
2. **Worker threads** - Non-blocking computation
3. **Timeouts (1000ms)** - Prevents hanging on large files
4. **File size checks** - Skips files that are too large
5. **Atomic decoration updates** - Prevents flickering
6. **Caching** - Reuses original model references
7. **Change comparison** - Only fires events if changes actually differ

## Summary for Lua Implementation

### Key Takeaways:

1. **Trigger on buffer changes** - Listen to `on_change` events
2. **Throttle aggressively** - Use 200ms delay (or configurable)
3. **Rerun full diff** - Don't try to patch incrementally
4. **Use async/non-blocking** - Run diff in coroutine or separate thread
5. **Atomic decoration updates** - Replace all decorations at once
6. **Cache original content** - Don't reload from disk each time
7. **Add timeout protection** - Limit diff time for large files
8. **Fire change events** - Let UI know when diff updates
9. **Handle external changes** - Listen to file system events
10. **Progress indication** - Show user activity for slow diffs

### Recommended Architecture:

```lua
-- Pseudo-code structure
local DiffModel = {
    throttle_delay = 200,  -- milliseconds
    max_computation_time = 1000,  -- milliseconds
    
    -- Triggers
    on_buffer_change = function() throttled_trigger_diff() end,
    on_file_external_change = function() trigger_diff_immediate() end,
    on_config_change = function() trigger_diff_immediate() end,
    
    -- Core computation
    compute_diff = async function()
        -- Full diff recomputation in background
        -- Use timeout protection
        -- Return changes array
    end,
    
    -- Decoration update
    update_decorations = function(changes)
        -- Atomic replacement of all decorations
        -- No incremental updates
    end
}
```
