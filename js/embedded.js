// Hide redundant page navigation only when a module is embedded by the unified portal.
// All standalone legacy page URLs retain their existing header and controls.
if(window.self!==window.top){
 document.documentElement.classList.add('portal-embedded-root');
 if(document.body)document.body.classList.add('portal-embedded');
 else document.addEventListener('DOMContentLoaded',()=>document.body?.classList.add('portal-embedded'),{once:true});
}