<!-- Thanks for the PR. Keep it focused — one thing per PR is the rule. -->

## Summary

<!-- 1-3 bullets. What changed and why. -->

## Test plan

<!-- How you verified the change. Even "ran swift build, opened the menu bar,
     watched a Claude idle page land" is fine. -->

- [ ] `swift build` clean
- [ ] `cd iOS && xcodebuild -project Page.xcodeproj -scheme Page -sdk iphonesimulator build` clean (if iOS touched)
- [ ] `cd Cloudflare && npx tsc --noEmit` clean (if Worker touched)
- [ ] Manual verification: ...

## Risk

<!-- What could break? Anything reviewers should look at especially carefully? -->

## Screenshots / log excerpts

<!-- For UI changes or new log lines. Optional. -->
