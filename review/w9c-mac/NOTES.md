# W9c Mac references: the two-finger space swipe

Build: a debug test bundle (dev.gabek.Kite.dev) from origin/main af3953c. Each capture used a fresh
`mktemp -d /tmp/k.XXXX` profile with windows/helix/states/two-spaces.json as session.json (selectedSpaceID set to the
space named below), `KITE_WINDOW_SIZE=1280,820`, `KITE_DIAGNOSTICS=1`, and Kite in the background throughout.

**Capture path:** in-process, `kite ui capture '{"source":"in-process"}'`, 2× (2560×1640). The `auto` source didn't
return within 30 s on this Mac, so every PNG is in-process: blurred materials are drawn unblurred (the sidebar
material over [0,0 1280×820] and [0,0 1280×28]), and the loading glow isn't drawn.

**Input that holds the swipe:** `{"scroll":[120,300],"dx":0,"phase":"began"}`, then one
`{"scroll":[120,300],"dx":D,"phase":"changed"}`. The pages stay where that leaves them until an `ended` (sent after
each capture). The tree read the same frames before and after each capture.

**dx sign:** positive dx moves the pages toward the next space (Work, to the right of Personal): the content slides
left. The first try was positive, so nothing needed redoing.

| file | selected | input | SidebarSpaceList frames (Personal, Work), window points |
|---|---|---|---|
| rest.png | Personal | none | [8,145 224×625], [248,145 224×625] |
| swipe-next-120.png | Personal | began 0, changed +120 | [-112,145 224×625], [128,145 224×625]: 120pt toward Work |
| swipe-past-end-100.png | Work (last) | began 0, changed +100 | [-276.75,145 224×625], [-36.75,145 224×625]: 44.75pt past the end for a 100pt pull |

For reference, Work at rest: [-232,145 224×625], [8,145 224×625]. The rubber band takes a 100pt pull past the last
space to 44.75pt.
