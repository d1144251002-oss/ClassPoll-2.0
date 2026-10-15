/* Static application shell only. Personal information, API calls and Auth never enter Cache Storage. */
const CACHE='classpoll-v3-static-v1';
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',event=>event.waitUntil((async()=>{
 const names=await caches.keys();
 await Promise.all(names.filter(name=>name.startsWith('classpoll-v3-static-')&&name!==CACHE).map(name=>caches.delete(name)));
 await self.clients.claim();
})()));
self.addEventListener('fetch',event=>{
 const req=event.request,url=new URL(req.url);
 if(req.method!=='GET'||url.origin!==self.location.origin||url.search||!url.pathname.includes('/app/'))return;
 if(req.mode==='navigate'||/\/api\/|\/auth\/|\/rest\/|\/realtime\//.test(url.pathname))return;
 if(!/\.(?:js|css|svg|woff2?|png|webp)$/.test(url.pathname))return;
 event.respondWith((async()=>{
  const cache=await caches.open(CACHE);
  try{const network=await fetch(req);
   if(network.ok && network.type==='basic')await cache.put(req,network.clone());
   return network;
  }catch(e){const cached=await cache.match(req);if(cached)return cached;throw e;}
 })());
});
