/* ClassPoll static-only service worker. Never cache school data, auth, API or answers. */
const CACHE='classpoll3-static-v1';
self.addEventListener('install',event=>{event.waitUntil(self.skipWaiting());});
self.addEventListener('activate',event=>{
 event.waitUntil((async()=>{
  const names=await caches.keys();
  await Promise.all(names.filter(n=>n.startsWith('classpoll3-static-')&&n!==CACHE).map(n=>caches.delete(n)));
  await self.clients.claim();
 })());
});
self.addEventListener('fetch',event=>{
 const request=event.request,url=new URL(request.url),scope=new URL(self.registration.scope);
 if(request.method!=='GET'||url.origin!==scope.origin||!url.pathname.startsWith(scope.pathname))return;
 const isAsset=/\/assets\/[^/]+\.(js|css|svg|woff2?)$/i.test(url.pathname);
 const isShell=request.mode==='navigate'&&url.pathname.startsWith(scope.pathname);
 if(!isAsset&&!isShell)return;
 event.respondWith((async()=>{
  const storage=await caches.open(CACHE);
  if(isAsset){
   const cached=await storage.match(request);
   if(cached)return cached;
   const response=await fetch(request);
   if(response.ok&&response.type==='basic')await storage.put(request,response.clone());
   return response;
  }
  try{
   const response=await fetch(request);
   if(response.ok&&response.type==='basic')await storage.put(request,response.clone());
   return response;
  }catch(e){
   const saved=await storage.match(request);
   if(saved)return saved;
   return new Response('目前離線，請重新連線後開啟校園平台。',{status:503,headers:{'Content-Type':'text/plain; charset=utf-8'}});
  }
 })());
});
