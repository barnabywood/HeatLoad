const pages = new Set(['/', '/features', '/apple-watch', '/garmin', '/insights', '/faq', '/support', '/sauna-on-apple-watch', '/sauna-calories-apple-watch']);
const campaigns = new Set(['website_home', 'website_hero', 'website_features', 'website_watch', 'website_garmin', 'website_insights', 'website_faq', 'website_support', 'website_seo', 'website_calories']);

export function onRequest({ request, params, env }) {
  const store = params.store;
  if (!['iphone', 'garmin'].includes(store)) return new Response('Not found', { status: 404 });
  if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });

  const url = new URL(request.url);
  const page = pages.has(url.searchParams.get('page')) ? url.searchParams.get('page') : '/';
  const placement = ['navigation', 'hero', 'content'].includes(url.searchParams.get('placement')) ? url.searchParams.get('placement') : 'content';
  const campaign = campaigns.has(url.searchParams.get('campaign')) ? url.searchParams.get('campaign') : 'website_home';
  const destination = store === 'iphone'
    ? `https://apps.apple.com/app/apple-store/id6759159351?pt=128428866&ct=${campaign}&mt=8`
    : 'https://apps.garmin.com/apps/62859187-a19d-4c30-8078-24aa6ce8e83e';

  const purpose = `${request.headers.get('Purpose') || ''} ${request.headers.get('Sec-Purpose') || ''}`;
  const automated = /bot|crawler|spider|preview|slurp|headless/i.test(request.headers.get('User-Agent') || '');
  const verifiedBot = request.cf?.botManagement?.verifiedBot === true;
  if (request.method === 'GET' && !automated && !verifiedBot && !/prefetch|prerender/i.test(purpose)) {
    // Aggregate only: no cookies, device IDs, IP addresses or referrer URLs.
    // Click requests are not unique people, installations or purchases.
    try {
      env.STORE_CLICKS?.writeDataPoint({ indexes: [store], blobs: [store, page, placement, store === 'iphone' ? campaign : ''], doubles: [1] });
    } catch (error) {
      console.warn('Store click metric unavailable');
    }
  }
  // A tracking failure must never stop somebody reaching a store.
  return new Response(null, { status: 302, headers: { Location: destination, 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex, nofollow' } });
}
