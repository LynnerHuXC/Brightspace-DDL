const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {JSDOM}=require('jsdom');
const parserPath=require('node:path').join(__dirname,'../Extension/parser.js');
const parser=fs.existsSync(parserPath)?require(parserPath):{parse:()=>null};
const doc=s=>new JSDOM(s).window.document;
const fixture=name=>doc(fs.readFileSync(`${__dirname}/fixtures/${name}.html`,'utf8'));
test('Gradescope uses due not release, and detects submitted',()=>{
 const p=parser.parse(fixture('gradescope'),'https://www.gradescope.com/courses/123');
 assert.ok(p,'supported page should produce assignments');
 const a=p.events.find(x=>x.id==='456');
 assert.equal(a.due,'2026-10-06T03:59:00.000Z');assert.equal(a.submitted,true);
 assert.equal(a.url,'https://www.gradescope.com/courses/123/assignments/456');
});
test('WebAssign EDT and EST with no inference from a full score',()=>{
 const p=parser.parse(fixture('webassign'),'https://www.webassign.net/v4cgi/student.pl?secret=DO_NOT_SAVE');
 assert.ok(p);assert.equal(p.events[0].due,'2026-09-29T03:59:00.000Z');
 assert.equal(p.events[1].due,'2026-11-03T04:59:00.000Z');assert.equal(p.events[0].submitted,null);
 assert.ok(!JSON.stringify(p).includes('DO_NOT_SAVE'));
});
test('WebAssign server partial home data uses epoch and labels coverage',()=>{
 const d=doc('<title>MA Example - Home | WebAssign</title><div data-assignments></div>');
 d.querySelector('div').setAttribute('data-assignments',JSON.stringify({current_assignments:[{id:123,name:'HW',due:{seconds:'1790654340'}}],past_assignments:[]}));
 const p=parser.parse(d,'https://webassign.net/v4cgi/student.pl');assert.ok(p);assert.equal(p.events.length,1);assert.equal(p.events[0].due,'2026-09-29T03:59:00.000Z');assert.ok(p.warning);
});
test('Login/unsupported pages must not count as successful empty snapshot',()=>{
 for(const url of ['https://www.gradescope.com/courses/123','https://webassign.net/v4cgi/student.pl','https://evil.example/courses/123']) assert.equal(parser.parse(doc('<h1>Login</h1>'),url),null);
});
test('Unknown dates never silently become today or release time',()=>{
 const d=fixture('gradescope'); for(const t of d.querySelectorAll('.submissionTimeChart--dueDate'))t.setAttribute('datetime','bad date');
 const p=parser.parse(d,'https://www.gradescope.com/courses/123');assert.ok(p);assert.equal(p.events.length,0);assert.ok(p.warning);
});
test('Unsubmitted button has stable id and excludes late deadline',()=>{
 const p=parser.parse(fixture('gradescope-unsubmitted'),'https://www.gradescope.com/courses/900000');
 const a=p.events.find(e=>e.id==='8732456');assert.ok(a);assert.equal(a.submitted,false);assert.equal(a.due,'2026-10-03T03:59:00.000Z');assert.equal(a.title,'PS 1');
 assert.ok(!JSON.stringify(p).includes('X-Amz'));
});
test('A submission detail link confirms submission even after grading replaces status text',()=>{
 const p=parser.parse(fixture('gradescope-unsubmitted'),'https://www.gradescope.com/courses/900000');
 assert.equal(p.events.find(e=>e.id==='900001').submitted,true);
});
test('A background refresh must not be rolled back by unchanged old DOM',async()=>{
 const vm=require('node:vm');let mutation;const sent=[];const old={version:1,events:[{due:'old',submitted:false}]}, fresh={version:1,events:[{due:'new',submitted:true}]};let listener;
 const context={document:{documentElement:{}},location:{href:'https://www.gradescope.com/courses/123',origin:'https://www.gradescope.com'},DDLParser:{parse:d=>d.fresh?fresh:old},
 chrome:{runtime:{sendMessage:async m=>{sent.push(m.payload);return {ok:true}},onMessage:{addListener:fn=>listener=fn}}},
 MutationObserver:class{constructor(fn){mutation=fn}observe(){}},setTimeout:fn=>{fn();return 1},clearTimeout(){},URL,AbortSignal,
 DOMParser:class{parseFromString(){return {fresh:true}}},fetch:async()=>({ok:true,url:'https://www.gradescope.com/courses/123',text:async()=>'<html></html>'})};
 vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname,'../Extension/content.js'),'utf8'),context);
 await new Promise(setImmediate);await new Promise(resolve=>listener({type:'refresh'},null,resolve));mutation();await new Promise(setImmediate);
 assert.deepEqual(sent.map(p=>p.events[0].due),['old','new']);
});
test('Keenly real cards: two dated tasks and six completed identities',()=>{
 const p=parser.parse(fixture('keenly'),'https://keenly.study/tasks',new Date('2026-09-30T16:00:00Z'));
 assert.ok(p);assert.equal(p.source,'keenly');assert.equal(p.events.length,2);
 assert.equal(p.events[0].due,'2026-10-01');assert.equal(p.events[0].dateOnly,true);
 assert.equal(p.events[0].course,'Problem Solving and Programming I');assert.equal(p.events[0].title,'Exercise-06');
 assert.equal(p.completedIDs.length,6);assert.equal(p.events[1].due,'2026-10-27');
});
test('Keenly login and empty loading shells cannot replace valid data',()=>{
 for(const html of ['<h2>Tasks</h2>','<h1>Login</h1>'])assert.equal(parser.parse(doc(html),'https://keenly.study/tasks'),null);
});
test('Keenly relative dates cross years and explicit timestamps keep offsets',()=>{
 const d=fixture('keenly');const links=d.querySelectorAll('a[href*="/tasks/"]');
 const p=parser.parse(d,'https://keenly.study/tasks',new Date(2026,11,31,12));assert.equal(p.events[0].due,'2027-01-01');
 const t=d.createElement('time');t.setAttribute('datetime','2026-11-01T23:30:00-05:00');links[0].append(t);
 const exact=parser.parse(d,'https://keenly.study/tasks',new Date(2026,9,31,12));assert.equal(exact.events[0].due,'2026-11-02T04:30:00.000Z');assert.equal(exact.events[0].dateOnly,false);
});
test('Keenly unsupported/malformed due stays unknown',()=>{
 const d=fixture('keenly');for(const s of d.querySelectorAll('span'))if(!s.children.length && /^Due /.test(s.textContent))s.textContent='Due Feb 30';
 const p=parser.parse(d,'https://keenly.study/tasks',new Date(2026,8,30,12));assert.equal(p.events.length,0);assert.equal(p.completedIDs.length,6);
});
test('Keenly background refresh owns its temporary tab and forwards date/status metadata',async()=>{
 const vm=require('node:vm');let listener;let state={};let removed=[];let nativePayload;let creates=0;
 const chrome={runtime:{id:'test',getURL:p=>'chrome-extension://test/'+p,sendNativeMessage:async(_h,p)=>{nativePayload=p;return {ok:true}},onMessage:{addListener:f=>listener=f},onInstalled:{addListener(){}},onStartup:{addListener(){}}},
 storage:{local:{set:async()=>{}},session:{get:async()=>state,set:async s=>Object.assign(state,s),remove:async k=>{delete state[k]}}},action:{setBadgeText:async()=>{}},
 alarms:{get:async()=>({}),create:async()=>{},clear:async()=>{},onAlarm:{addListener(){}}},
 tabs:{query:async()=>[{id:1,url:'https://keenly.study/tasks'}],create:async o=>{assert.equal(o.active,false);creates++;return {id:99}},remove:async id=>removed.push(id),get:async()=>({url:'https://keenly.study/tasks'}),sendMessage:async()=>{throw Error('must not refresh existing Keenly tab')}}};
 vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname,'../Extension/background.js'),'utf8'),{chrome,URL,console});
 await Promise.all([1,2].map(()=>new Promise(resolve=>listener({type:'refreshAll'},{url:'chrome-extension://test/popup.html'},resolve))));assert.equal(creates,1);
 const payload=parser.parse(fixture('keenly'),'https://keenly.study/tasks',new Date(2026,8,30,12));
 await new Promise(resolve=>listener({type:'snapshot',payload},{id:'test',frameId:0,tab:{id:99},url:'https://keenly.study/tasks'},resolve));await new Promise(setImmediate);
 assert.deepEqual(removed,[99]);assert.equal(nativePayload.events[0].dateOnly,true);assert.equal(nativePayload.completedIDs.length,6);
});

test('Keenly title text is never interpreted as completion',()=>{
 const d=fixture('keenly');d.querySelector('span.block.truncate').textContent='Feedback ready exercise';
 const p=parser.parse(d,'https://keenly.study/tasks',new Date(2026,8,30,12));assert.equal(p.events.length,2);assert.equal(p.completedIDs.length,6);
});
test('Keenly old document cannot publish freshly rendered relative dates on a later day',async()=>{
 const vm=require('node:vm');let mutation,time=new Date(2026,8,30,12).getTime(),title='old';const sent=[];
 class Clock extends Date {constructor(...args){super(...(args.length?args:[time]));}}
 vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname,'../Extension/content.js'),'utf8'),{
 Date:Clock,document:{documentElement:{}},location:{href:'https://keenly.study/tasks',hostname:'keenly.study'},DDLParser:{parse:()=>({title})},
 chrome:{runtime:{sendMessage:async m=>{sent.push(m.payload);return {ok:true}},onMessage:{addListener(){}}}},MutationObserver:class{constructor(f){mutation=f}observe(){}},setTimeout:f=>{f();return 1},clearTimeout(){}});
 await new Promise(setImmediate);time=new Date(2026,9,1,12).getTime();title='new';mutation();await new Promise(setImmediate);assert.equal(sent.length,1);
});
