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

The local multilingual `privacy.html` is also published; the GitHub policy remains available for existing app links.

## Store click measurement

Direct App Store / Connect IQ links remain in the HTML as the no-JavaScript fallback. On a real click, `script.js` changes the link to `/go/iphone` or `/go/garmin`. The Pages Function redirects to the fixed store listing with Apple's original campaign parameters intact. Other domains cannot be supplied as redirect destinations.

To enable persistent aggregate click counts, add an **Analytics Engine** binding in Cloudflare Pages → `sauna-log` → Settings → Bindings, named `STORE_CLICKS`, dataset `saunalog_store_clicks`, then redeploy. The Function still redirects correctly if the binding is absent or metrics fail. There is no claim that recording is active until that binding has been added and a production click verified.

The dataset fields are `blob1` store, `blob2` source page, `blob3` button placement, `blob4` Apple campaign, and `double1` count. No cookies, IP addresses, full referrer URLs or visitor identifiers are recorded by this custom metric. HEAD requests, known bot agents and prefetch requests are excluded. Other automated requests can still be counted; these are click requests, not unique humans or downloads.

Example Analytics Engine query (counts respect dataset sampling):

```sql
SELECT blob1 AS store, blob2 AS page, blob3 AS placement,
       SUM(_sample_interval * double1) AS clicks
FROM saunalog_store_clicks
WHERE timestamp >= NOW() - INTERVAL '30' DAY
GROUP BY store, page, placement
ORDER BY clicks DESC
```

Compare these counts with App Store Connect campaign downloads and purchases. The website cannot observe Garmin installations or in-app purchases directly. Cloudflare zone unique visitors are not the denominator for a reliable app purchase conversion rate.

## Image delivery

On-page product images use WebP at 640px and 1024px widths. Below-fold images are lazy loaded; hero images load eagerly. The original PNG files are retained for social previews and source artwork, but are not downloaded by the on-page image elements. The 96px WebP icon avoids downloading the large source PNG for the navigation logo.
