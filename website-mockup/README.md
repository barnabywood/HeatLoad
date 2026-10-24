# Sauna Log Website Mockup

Static marketing site for `saunalogapp.com`. Published to the Cloudflare Pages project `sauna-log` (`sauna-log-av3.pages.dev`).

## Pages

- `index.html` - conversion-focused landing page
- `features.html` - feature overview
- `apple-watch.html` - Apple Watch session flow
- `insights.html` - long-term progress and Insights
- `faq.html` - search-friendly user questions
- `support.html` - installation, HealthKit, purchase and feature-request support

Cloudflare Pages also serves `/.well-known/security.txt` for vulnerability disclosure and redirects the `www` hostname to the apex domain.

## App Store campaign links

Download links use Apple's complete campaign URL format. Provider token `128428866` was obtained from Sauna Log's App Store Connect campaign generator on 11 September 2026. Keep this provider token and the existing per-page `ct=` campaign names on all download links, including mobile navigation.

Example: `https://apps.apple.com/app/apple-store/id6759159351?pt=128428866&ct=website_home&mt=8`

Apple only displays a campaign after downloads from at least five individual Apple Accounts; an empty campaign report does not by itself mean the links are broken.

Campaign names:

- `website_home`
- `website_hero`
- `website_features`
- `website_watch`
- `website_insights`
- `website_faq`
- `website_support`

The App Store ID used here is `6759159351`.

## Privacy

The site links directly to the existing policy:

https://barnabywood.github.io/HeatLoad/privacy-policy.html

No duplicate privacy page is included.
