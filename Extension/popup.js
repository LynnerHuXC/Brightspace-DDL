async function render(){
 const data=await chrome.storage.local.get(['gradescope','webassign','keenly','aleks']);
 const container=document.querySelector('#status');container.replaceChildren();
 for(const [key,name] of [['gradescope','Gradescope'],['webassign','Cengage / WebAssign'],['keenly','Keenly Tasks'],['aleks','ALEKS']]){
  const s=data[key], row=document.createElement('section');
  row.textContent=name+'\n'+(!s?'尚未连接':s.ok?`${s.course}\n已同步 ${s.count} 项 · ${new Date(s.time).toLocaleString()}${s.warning?'\n'+s.warning:''}`:s.message);container.append(row);
 }
}
document.querySelector('#refresh').addEventListener('click',async()=>{await chrome.runtime.sendMessage({type:'refreshAll'});await render();});
chrome.storage.onChanged.addListener(render);render();
