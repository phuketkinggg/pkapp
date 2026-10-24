// Pangea website and app on pangeaglobalwellness.com.
// app.pangeaglobalwellness.com shows the Pangea app, which lives with the Phuket King app (app.phuketking.com/pangea/).
// Every other address serves the website files in this folder.
const APP = 'https://app.phuketking.com';
export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.hostname === 'app.pangeaglobalwellness.com') {
      const path = url.pathname.startsWith('/vendor/') ? url.pathname : '/pangea' + url.pathname;
      const res = await fetch(APP + path + url.search, { method: req.method, headers: { accept: req.headers.get('accept') || '*/*' }, redirect: 'follow' });
      const h = new Headers(res.headers);
      h.delete('set-cookie');
      return new Response(res.body, { status: res.status, headers: h });
    }
    return env.ASSETS.fetch(req);
  },
};
