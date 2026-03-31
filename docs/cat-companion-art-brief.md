# C.C. Art Brief

`C.C.` is the simulator cat companion that visualizes Blitz iPhone actions around the simulator stage. Codex intentionally leaves the art as a stub; Claude Code owns final sprite art.

## Deliverable

- Provide a pixel-art cat sprite sheet at roughly `200 x 500` pixels per full-body pose.
- Camera is mostly top-down, but not perfectly parallel to the floor.
- The cat should read as a top-down cat at a slight angle, with visible head, shoulders, back, hips, tail, and paws.
- The cat enters from the left or right side of the simulator phone and appears to paw/swipe into the screen edge.
- The cat also needs idle / roll / flop poses for the extra empty stage area around the simulator.

## Required Poses

- `idle_loaf_left`
- `idle_loaf_right`
- `side_swipe_left`
- `side_swipe_right`
- `roll_left`
- `roll_right`
- `belly_up_play`
- `tail_flick_loop`

## Motion Notes

- `side_swipe_*` should feel like the cat is standing beside the phone and reaching inward with one or both paws.
- `roll_*` should work in the open space above, below, or to the sides of the phone.
- Idle frames should look good when drifting slowly, not only when perfectly static.
- Keep silhouette clarity strong enough that the cat still reads when scaled down to around `90-140 px` tall in the simulator tab.

## Style Notes

- Pixel art only. No soft airbrush shading.
- Keep palette warm and readable against a charcoal / slate simulator stage background.
- Strong dark outline is preferred so the cat survives over mixed backgrounds and shader glow.
- Tail shape needs to stay legible during motion.
- The art should feel mischievous and playful, not cute-plush or mascot-flat.

## Packing Contract

- Export a single atlas PNG with consistent frame boxes.
- Keep transparent padding around each pose.
- Provide a JSON manifest with:
  - pose name
  - frame rect in pixels
  - pivot point in normalized coordinates
  - recommended facing direction
- The renderer currently uses procedural placeholder cats in [src/services/simulator/SimulatorCatRenderer.swift](/Users/minjunes/superapp/blitz-macos/src/services/simulator/SimulatorCatRenderer.swift).
- Replace that shader shape generation with atlas sampling once the sprite sheet exists. Preserve the same pose names so Swift-side choreography does not change.

## Integration Expectations

- The simulator tab keeps the real phone render centered.
- Cats occupy only the spare simulator-tab area outside the phone frame.
- The cat-only fullscreen window should reuse the same art assets but may scale them much larger.
- Art must look acceptable both over the normal simulator stage and in cat-only fullscreen.
