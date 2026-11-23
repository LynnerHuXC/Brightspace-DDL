const HOST='local.brightspace.ddl';
const patterns=['https://*.aleks.com/*','https://keenly.study/tasks','https://keenly.study/tasks/','https://gradescope.com/courses/*','https://www.gradescope.com/courses/*','https://webassign.net/v4cgi/student.pl*','https://www.webassign.net/v4cgi/student.pl*'];
function sourceFor(sender) {
  if(sender.id!==chrome.runtime.id || sender.frameId!==0 || !sender.tab)return null;
  const u=new URL(sender.url);
  if(u.protocol!=='https:')return null;
  if(['gradescope.com','www.gradescope.com'].includes(u.hostname)&&/^\/courses\/\d+\/?$/.test(u.pathname))return 'gradescope';
  if(['webassign.net','www.webassign.net'].includes(u.hostname)&&u.pathname==='/v4cgi/student.pl')return 'webassign';
  if(u.hostname==='keenly.study' && /^\/tasks\/?$/.test(u.pathname))return 'keenly';
  if (/(^|\.)aleks\.com$/.test(u.hostname)) return 'aleks';
  return null;
}
async function recordStatus(source,value) {
  await chrome.storage.local.set({[source]:value});
  await chrome.action.setBadgeText({text:value.ok?'':'!'});
}
let queue=Promise.resolve();
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
  if(message.type==='refreshAll' && sender.url===chrome.runtime.getURL('popup.html')) {
    refreshAll().then(()=>reply({ok:true}));return true;
  }
  let source;try{source=sourceFor(sender);}catch{return;}
  if(!source)return;
  if(message.type==='failure') {
    recordStatus(source,{ok:false,message:'同步失败或登录失效，请打开课程页面。'}).then(()=>reply({ok:false}));return true;
  }
  if(message.type!=='snapshot' || message.payload?.source!==source)return;
  const p=message.payload;
  if(p.version!==1 || typeof p.course!=='string' || typeof p.courseKey!=='string' || !Array.isArray(p.events) || p.events.length>2000)return;
  if(source==='gradescope' && p.courseKey!==new URL(sender.url).pathname.split('/')[2])return;
  // Explicit whitelist: never relay arbitrary fields from a page to the local process.
  const payload={version:1,source,course:p.course,courseKey:p.courseKey,completedIDs:source==='keenly'&&Array.isArray(p.completedIDs)?p.completedIDs:[],warning:typeof p.warning==='string'?p.warning:null,
    events:p.events.map(e=>({id:e.id,title:e.title,course:source==='keenly'?e.course:null,dateOnly:source==='keenly'&&e.dateOnly===true,due:e.due,submitted:typeof e.submitted==='boolean'?e.submitted:null,url:e.url}))};
  queue=queue.catch(()=>{}).then(async()=>{
    try {
      const result=await chrome.runtime.sendNativeMessage(HOST,payload);
      if(!result?.ok)throw new Error('invalid snapshot');
      await recordStatus(source,{ok:true,time:Date.now(),count:p.events.length,course:p.course,warning:p.warning});reply({ok:true});
      if(source==='keenly')await closeKeenlyRefresh(sender.tab.id);
    }catch{await recordStatus(source,{ok:false,message:'无法连接 Mac App，请安装本机连接组件。'});reply({ok:false});}
  });return true;
});
async function closeKeenlyRefresh(tabId) {
  const {keenlyRefresh}=await chrome.storage.session.get('keenlyRefresh');
  if(keenlyRefresh?.id===tabId){await chrome.storage.session.remove('keenlyRefresh');await chrome.alarms.clear('keenly-cleanup');await chrome.tabs.remove(tabId).catch(()=>{});}
}
let keenlyRefreshPromise;
function refreshKeenly() {
  if(keenlyRefreshPromise)return keenlyRefreshPromise;
  keenlyRefreshPromise=(async()=>{
    const {keenlyRefresh}=await chrome.storage.session.get('keenlyRefresh');
    if(keenlyRefresh)await closeKeenlyRefresh(keenlyRefresh.id);
    const tab=await chrome.tabs.create({url:'https://keenly.study/tasks',active:false});
    await chrome.storage.session.set({keenlyRefresh:{id:tab.id}});
    await chrome.alarms.create('keenly-cleanup',{delayInMinutes:1});
  })().finally(()=>{keenlyRefreshPromise=null;});
  return keenlyRefreshPromise;
}
async function refreshAll() {
  const tabs=await chrome.tabs.query({url:patterns});
  if(tabs.some(t=>new URL(t.url).hostname==='keenly.study'))await refreshKeenly();
  await Promise.allSettled(tabs.filter(t=>new URL(t.url).hostname!=='keenly.study').map(t=>chrome.tabs.sendMessage(t.id,{type:'refresh'})));
}
async function ensureAlarm(){if(!await chrome.alarms.get('ddl-hourly'))await chrome.alarms.create('ddl-hourly',{periodInMinutes:60});}
chrome.runtime.onInstalled.addListener(ensureAlarm);
chrome.runtime.onStartup.addListener(()=>{ensureAlarm();refreshAll();});
chrome.alarms.onAlarm.addListener(async a=>{
  if(a.name==='ddl-hourly')await refreshAll();
  if(a.name==='keenly-cleanup'){const {keenlyRefresh}=await chrome.storage.session.get('keenlyRefresh');if(keenlyRefresh){await recordStatus('keenly',{ok:false,message:'Keenly 未能加载任务，请检查登录；已保留旧数据。'});await closeKeenlyRefresh(keenlyRefresh.id);}}
});
ensureAlarm();
