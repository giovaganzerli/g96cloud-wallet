# Wallet branding

The `g96-custom` branch preserves a personal branding layer on top of Sure
v0.7.5-hotfix.2. Keep upstream changes available through a separate `upstream`
remote pointing to https://github.com/we-promise/sure.git.

The current icon is `public/branding/wallet-8ad5b8fbb493-512.png`. It uses RGBA
transparency outside the green circular illustration. Smaller PNGs, a multi-size
ICO and a padded maskable icon are in the same directory. Standard public icon
paths are also updated for clients that request them directly.

Layouts and the PWA manifest reference versioned asset paths. The offline service
worker cache version changes with the icon version. Keep these references aligned
when updating the artwork; installed PWAs may retain their old icon until their
launcher refreshes it.

`PRODUCT_NAME=Wallet` controls the name used by the app and PWA. This is the default
in this fork's Compose example; native Rails deployments should set the variable
explicitly. Layout titles use `Giovanni Ganzerli | Wallet`. Keep the upstream
license and attribution in place.

For future community updates, fetch upstream tags and merge the selected release
into an integration branch derived from `g96-custom`. Review conflicts in layouts,
the PWA manifest, service worker and public assets. Run the repository's required
checks before publishing. A Git push does not update an existing deployment.
