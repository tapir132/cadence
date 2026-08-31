# Cadence Engineering Notes

These instructions apply to every change in this repository. Read them before debugging, testing, or releasing Cadence.

## Debug the observed behavior

- Reproduce the exact behavior the user reported before changing nearby code.
- Trace the full path from input event to the visible result. Do not stop after confirming that an intermediate handler, state value, or target calculation is correct.
- When internal state is correct but the UI is wrong, inspect the final framework or operating-system API call directly.
- Reduce uncertain framework behavior to a minimal experiment. Verify assumptions about AppKit, SwiftUI, accessibility, event delivery, animation proxies, and window management instead of relying on memory.
- A repeated user report means the current reproduction or test is incomplete. Reassess the test before attempting another speculative fix.
- Prefer evidence from the running app over evidence that the implementation merely reached the expected code path.

## Test what the user can see

- Unit-test pure logic such as snap geometry, placement selection, clamping, and preference persistence.
- Add an integration or UI-level check for behavior involving real `NSWindow`/`NSPanel` movement, AppKit animation, focus, permissions, global shortcuts, or accessibility APIs.
- For drag behavior, test multiple consecutive drags and every snap destination. Verify the panel's actual on-screen frame after each completed animation.
- Test modifier-key alternatives such as Command-drag free placement separately.
- Confirm screen bounds, multi-display behavior, and visible-frame constraints where applicable.
- Never call a visual interaction fixed solely because its calculated destination or internal model state is correct.

## Regression lesson: window snapping

The snap destination can be correct while the panel remains stationary. In one real failure, `panel.animator().setFrameOrigin(target)` was silently ignored by the `NSWindow` animation proxy. Animating the complete frame worked:

```swift
panel.animator().setFrame(
    NSRect(origin: target, size: panel.frame.size),
    display: true
)
```

When debugging similar failures, separately verify event tracking, destination calculation, the final window API call, animation completion, and the resulting on-screen frame.

## Release verification

- Run the complete test suite with warnings treated as errors.
- Build the production `.app` and verify its bundle signature.
- Keep commits focused and preserve unrelated user changes.
- After pushing an Edge build, wait for the GitHub workflow to finish and verify that the published appcast references the new commit.
- Test the exact artifact delivered through the updater when a bug could differ between local and published builds.
- Do not create a stable release for every commit. Stable releases require an intentional release decision; Edge builds may follow `main`.
- Do not claim completion until the original user-visible failure has been reproduced and verified as fixed, or clearly state which verification could not be performed.

## Public repository hygiene

- Do not commit secrets, credentials, signing keys, tokens, private URLs, personal data, or machine-specific absolute paths.
- Keep documentation useful to public contributors and phrase notes as durable engineering guidance.
