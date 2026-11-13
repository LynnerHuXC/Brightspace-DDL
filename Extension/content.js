(() => {
  let busy=false, lastDOMDigest='';
  const pageLoadedAt=new Date();
  async function send(document, force=false) {
    // A live SPA may render a fresh relative label long after the document loaded.
    // The hourly fresh tab owns cross-day captures; an old tab cannot overwrite them.
    if(location.hostname==='keenly.study' && new Date().toDateString()!==pageLoadedAt.toDateString())return false;
    const payload=DDLParser.parse(document,location.href,pageLoadedAt);
    if(!payload)return false;
    const digest=JSON.stringify(payload);
    if(!force && digest===lastDOMDigest)return true;
    const response=await chrome.runtime.sendMessage({type:'snapshot',payload});
    if(!response?.ok)throw new Error('native connection');
    if(!force)lastDOMDigest=digest;return true;
  }
  async function refresh() {
    if(busy)return;busy=true;
    try {
      // GET only. Never reload the user's tab or touch assignment forms.
      const supported=DDLParser.parse(document,location.href,pageLoadedAt);
      if(!supported)return;
      const response=await fetch(location.href,{credentials:'same-origin',cache:'no-store',signal:AbortSignal.timeout(25000)});
      if(!response.ok || response.url && new URL(response.url).origin!==location.origin)throw new Error('login or network');
      const html=await response.text();
      if(html.length>10000000 || !await send(new DOMParser().parseFromString(html,'text/html'),true))throw new Error('unrecognized page');
    } catch {
      await chrome.runtime.sendMessage({type:'failure',source:location.hostname==='keenly.study'?'keenly':location.hostname.includes('gradescope')?'gradescope':'webassign'}).catch(()=>{});
    } finally {busy=false;}
  }
  chrome.runtime.onMessage.addListener((m,_s,reply)=>{
    if(m.type==='refresh'){refresh().then(()=>reply({ok:true}));return true;}
  });
  // Capture a real page load and SPA changes, without repeatedly marking an unchanged DOM fresh.
  let timer;
  new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(()=>send(document).catch(()=>{}),1200);})
    .observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['datetime','data-assignments']});
  if(location.hostname==='keenly.study')timer=setTimeout(()=>send(document).catch(()=>{}),1500);
  else send(document).catch(()=>{});
})();
