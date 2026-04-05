# Changelog

## 1.0.33
- Fixed codex breaking in built-in terminal
- Show Review messages only when the attached version is selected in Overview tab
- Lots of bug fixes
- Minimal usage analytics to improve Blitz - no personal info whatsoever logged

## 1.0.32
Features
- Live gesture visualization overlays to see agents tap/swipe on simulator
- Automatically discover bundle IDs when importing projects already on App Store

Bug fixes
- Improved release version selection/update flow by ignoring stale historical versions when choosing defaults
- Improved imported project metadata/icon hydration and local blitz-iphone MCP command resolution

## 1.0.31
- New App Wall showing average review time, rejection ratio, and # rejects until success
- Version-aware ASC release workflow with create/update flow and unified version picker
- Better ASC diagnostics, fetch resilience, and project switching reliability
- Dashboard and app grid polish, plus improved launch logging

## 1.0.30
- New built-in terminal 
- New Dashboard and App navigation
- Project switching performance improvements
- Share ASC auth between asc-cli and Blitz MCP tools  
- Improved release/update reliability and simulator behavior
- Localization fixes (screenshot, store listing, overview tab)

## 1.0.29
- Faster App Store Connect setup with improved onboarding, credential entry, and bundle ID guidance
- Better review workflows with rejection feedback in Overview and Review, plus a submission history timeline
- More reliable ASC automation: pricing fixes, auth/session handling, screenshot support, and terminal fallbacks
- Release pipeline improvements including Intel builds, leaner packaging, and better Codex/MCP project setup

## 1.0.26
- ASC CLI skills: auto-provision 21 App Store Connect skills into each project's .claude/skills/
- Auto-install asc CLI if not present on the system
- Fix Apple ID email not captured during auto-create flow (sync XHR + ephemeral URLSession fallback)
- Auto-create via Claude Code now cd's into project dir so skills are discovered
- Fix shell injection in Terminal launch for auto-create flow

## 1.0.25
- Add App Store rejection feedback 
- Screenshot track-based workflow: arrange, reorder, and sync screenshots to ASC
- Paginate in-app purchases and subscriptions (up to 200 per page)
- App store review agent for Claude Code available in Blitz projects
- New MCP tools: screenshots_add_asset, screenshots_set_track, screenshots_save, get_rejection_feedback

## 1.0.24
Mac App Support! Now you can import or create macOS applications and upload to the App Store. 

## 1.0.23
- Improve auto-update UX: faster dialog, indeterminate progress, no admin prompt

## 1.0.20
- Better instructions for App Store Connect API key generation

## 1.0.19
- Hardcode FPS to 50

## 1.0.18
- MCP tool bug fix

## 1.0.11 
- Clear TCC bug fix

## 1.0.10
- Simulator bug fixes and pkg script fix

## 1.0.9
- Fix MCP bridge dropping responses when Claude Code sends notifications (root cause of asc_fill_form hanging)
- Fix App Store build for Xcode 26 (manual distribution signing, export method "app-store")
- Add early guard when provisioning profile is missing from app_store_build
- Fix MCP server rejecting notification messages that have no JSON-RPC id
- Add --max-time to bridge script curl to prevent silent hangs
- Add RN project template, remove warm-template logic
- Fix screenshot counts showing 0 in submission readiness
- Fix sidebar push caused by HSplitView in detail views

## 1.0.8
- Test Auto Update UI fix
## 1.0.7
- Auto Update UI fix 

## 1.0.6 
- Test Auto-Update Logic 

## 1.0.5
- Bug fixes

## 1.0.4
- Bug fixes

## 1.0.3
- Fix app crash on launch caused by Bundle.module failing to locate SPM resource bundle in .app
- Add auto-update: app checks for updates on launch and can download/install in-place
- Embed pkg-scripts in .app bundle for auto-updater to run postinstall on update

## 1.0.2
- Initial release of blitz-macos: native Swift rewrite of Blitz
