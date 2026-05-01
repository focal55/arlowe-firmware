<!--
PR Reviewer agent reads this template. Fill it out completely.
Atomic PRs only — one issue, one logical change, <400 lines net.
-->

## Linked issue

Closes #

## Summary

<!-- One paragraph: what changed and why. The "why" should match the issue's "Why now" or motivation. -->

## Approach

<!-- 2-4 sentences on the implementation strategy. What did you choose, what did you reject, why. -->

## Out of scope

<!-- What this PR explicitly does NOT do. Helps the reviewer hold the line on scope creep. -->

## Tests

<!-- How is this verified? Which tests cover what? Manual testing notes if any. -->

- [ ] All acceptance criteria from linked issue covered by tests
- [ ] Edge cases covered (boundary, empty, error paths)
- [ ] CI green

## Reviewer checklist

<!-- The PR-Reviewer agent works through this. Author should also self-check. -->

- [ ] Scope: matches the linked issue, no drift
- [ ] Tests: meaningful, not weakened, CI green
- [ ] Conventions: file structure, naming, commit format match project
- [ ] Architecture: aligns with ADRs and CLAUDE.md
- [ ] Security: no secrets, no injection surfaces, validation at boundaries
- [ ] No emojis, no comments-explaining-what, no commented-out code

## Notes for reviewer

<!-- Anything the reviewer should know that isn't obvious from the diff. -->
