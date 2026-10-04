# omarchy-dragon-sl7

Omarchy on the Surface Laptop 7. The Snapdragon X Plus (X1P-64-100) model
comes first, with X Elite support where it is cheap to add. This project is a
thin overlay on upstream omacom/omarchy and omarchy-iso dragon branches. It
ships its own linux-sl7 kernel, and firmware is fetched at install time and
never redistributed.

## Status

Planning / pre-alpha. Nothing to install yet. See [PLAN.md](PLAN.md).

## Firmware and licensing

Microsoft and Qualcomm firmware is never committed to or distributed from this
repository. It is fetched on the target machine from Microsoft's public
Surface Laptop 7 driver MSI. The .gitignore blocks firmware and captures.

License: TBD

## Credits

Built on the work of the community: omacom/omarchy dragon work,
denislopt/omarchy-surface-laptop7, bryce-hoehn/linux-surface-laptop-7,
ProgrammerIn-wonderland/ELLX-Kernel,
ItsLucas/surface-laptop-7-ubuntu-kernel, dwhinham/linux-sp11, and
linux-surface.
