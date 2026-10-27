document.querySelectorAll('[data-year]').forEach((el) => { el.textContent = new Date().getFullYear(); });

const currentPath = window.location.pathname.replace(/\.html$/, '').replace(/\/$/, '') || '/';
document.querySelectorAll('header nav a').forEach((link) => {
  if (link.getAttribute('href') === currentPath) link.setAttribute('aria-current', 'page');
});

const mobileMenu = document.querySelector('.mobile-menu');
if (mobileMenu) {
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && mobileMenu.open) {
      mobileMenu.open = false;
      mobileMenu.querySelector('summary').focus();
    }
  });
  document.addEventListener('click', (event) => {
    if (!mobileMenu.contains(event.target)) mobileMenu.open = false;
  });
  mobileMenu.querySelectorAll('a').forEach((link) => {
    link.addEventListener('click', () => { mobileMenu.open = false; });
  });
}

// Keep direct store URLs as the no-JavaScript fallback. Only a real activation
// uses the click route, so link previews and speculative loading are not clicks.
document.addEventListener('click', (event) => {
  if (!event.isTrusted || event.defaultPrevented) return;
  const link = event.target.closest('a[href]');
  if (!link) return;
  const destination = new URL(link.href, window.location.href);
  const store = destination.hostname === 'apps.apple.com' ? 'iphone'
    : destination.hostname === 'apps.garmin.com' ? 'garmin' : null;
  if (!store) return;
  const placement = link.closest('header') ? 'navigation'
    : link.closest('.hero, .page-hero') ? 'hero' : 'content';
  const route = new URL(`/go/${store}`, window.location.origin);
  route.searchParams.set('page', currentPath);
  route.searchParams.set('placement', placement);
  if (store === 'iphone') route.searchParams.set('campaign', destination.searchParams.get('ct') || 'website_home');
  link.href = route.href;
});
