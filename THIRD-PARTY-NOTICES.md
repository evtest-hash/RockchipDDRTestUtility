# Third-party notices

## libusb

Both shipped binaries — the GUI app and the standalone CLI — **statically link
libusb**. That is what lets the CLI ship as a single executable and the app
bundle carry no `Frameworks/` dylib.

| | |
|---|---|
| Component | libusb |
| Version | 1.0.27 (pinned in [`scripts/package.sh`](scripts/package.sh)) |
| Upstream source | <https://github.com/libusb/libusb/releases/tag/v1.0.27> — the exact tarball `package.sh` downloads |
| License | **LGPL-2.1-or-later** — full text in [`third-party/libusb/COPYING`](third-party/libusb/COPYING) |
| Authors | [`third-party/libusb/AUTHORS`](third-party/libusb/AUTHORS) |
| Modifications | none; used as published |

### Relinking against your own libusb

Dynamic linking let a recipient swap the dylib. Static linking does not, so the
LGPL asks that the means to relink be available instead. For this project that
is the repository itself:

1. Its complete source is public, and `scripts/package.sh` performs the whole
   link — fetch libusb 1.0.27, build one static slice per architecture, merge,
   link both executables against the result.
2. Point that script at a different libusb (`LIBUSB_BREW`, or an archive of your
   own in place of the fetched one) and the binaries link against yours.
3. libusb's own source is available at the pinned upstream URL above, and its
   license text travels with this repository.

No prebuilt libusb archive is attached to releases; the source and the build
that produces it are the designated place to obtain the materials.

*This records what the project does, not legal advice. Distributing these
binaries outside the public repository — to a customer, on internal media —
means the same materials have to be reachable by those recipients too, which the
public repository provides as long as they can reach it.*
