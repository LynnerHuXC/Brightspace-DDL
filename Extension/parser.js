/* Only assignment metadata leaves this parser. No session URLs or grades. */
(function(root) {
  const text = node => (node?.textContent || '').replace(/\s+/g, ' ').trim();
  const iso = value => { const d = new Date(value); return Number.isFinite(d.getTime()) ? d.toISOString() : null; };
  function keenly(doc, now) {
    const groups=[...doc.querySelectorAll('section[aria-labelledby]')].filter(s=>s.querySelector('a[href*="/tasks/"]'));
    if(!groups.length)return null;
    const events=[], completedIDs=[];let skipped=0;
    const dayString=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
    for(const group of groups)for(const link of group.querySelectorAll('a[href]')) {
      let u;try{u=new URL(link.getAttribute('href'),'https://keenly.study');}catch{continue;}
      const id=u.origin==='https://keenly.study' && u.pathname.match(/^\/tasks\/([A-Za-z0-9_-]{1,100})$/)?.[1];
      if(!id)continue;
      const heading=text(group.querySelector('h2'));
      const leaves=[...link.querySelectorAll('span')].filter(n=>!n.children.length).map(text).filter(Boolean);
      if(/^Done(?:\s|\d|$)/.test(heading) || /^(Submitted|Done|Feedback ready)(?:\b|$)/.test(text(link.lastElementChild))) {completedIDs.push(id);continue;}
      const title=text(link.querySelector('span.block.truncate'));
      const course=text(link.querySelector('span.truncate:not(.block)'));
      const label=leaves.find(t=>/^Due /.test(t));
      let due=null,dateOnly=true;
      const raw=link.querySelector('time[datetime]')?.getAttribute('datetime');
      if(raw && /^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(raw)){due=iso(raw);dateOnly=false;}
      else if(raw && /^\d{4}-\d{2}-\d{2}$/.test(raw))due=raw;
      else if(label) {
        const date=new Date(now.getFullYear(),now.getMonth(),now.getDate(),12);
        const relative=label.match(/^Due (today|tomorrow|yesterday)$/i);
        if(relative){date.setDate(date.getDate()+({today:0,tomorrow:1,yesterday:-1}[relative[1].toLowerCase()]));due=dayString(date);}
        else {
          const m=label.match(/^Due ([A-Z][a-z]{2}) (\d{1,2})(?:,? (\d{4}))?$/);
          const month=m ? ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'].indexOf(m[1]) : -1;
          if(m && month>=0) {
            let year=m[3]?Number(m[3]):now.getFullYear();
            if(!m[3] && /^Later/.test(heading) && month<now.getMonth())year++;
            const d=new Date(year,month,Number(m[2]),12);
            if(d.getMonth()===month && d.getDate()===Number(m[2]))due=dayString(d);
          }
        }
      }
      if(!title || !course || !due){skipped++;continue;}
      events.push({id,title,course,due,dateOnly,submitted:false,url:`https://keenly.study/tasks/${id}`});
    }
    return {version:1,source:'keenly',courseKey:'tasks',course:'Keenly Tasks',events,completedIDs,
      warning:`页面日期未标明时间时按日期提醒；相对日期按页面加载日换算，未标年份按当前年份（跨年 Later 按下一年）。${skipped?`${skipped} 项日期无法确认，已跳过。`:''}`};
  }
  function aleks(doc) {
    const course = (doc.body?.innerText || '').match(/\bCM-UY[^\n]*?\b(?:Fall|Spring|Summer)\s+20\d{2}/i)?.[0]?.replace(/\s+/g, ' ') ||
      text(doc.querySelector('main h1, h1')).replace(/^Assignments$/i, '') ||
      (doc.title || '').replace(/\s+-\s+(?:Home|Assignments|ALEKS)$/i, '').trim();
    if (!course || /^(ALEKS|Assignments|Home)$/i.test(course) || course.length > 500) return null;
    const clock = new Intl.DateTimeFormat('en-GB', {
      timeZone:'America/New_York', year:'numeric', month:'2-digit', day:'2-digit',
      hour:'2-digit', minute:'2-digit', hourCycle:'h23'
    });
    const events = new Map(), duplicates = new Set();
    let skipped = 0;
    for (const grid of doc.querySelectorAll('[role="grid"]')) {
      const headers = [...grid.querySelectorAll('tr')].find(row =>
        [...row.cells].some(cell => /^Due(?: Date)?$/i.test(text(cell))));
      if (!headers) continue;
      const dueIndex = [...headers.cells].findIndex(cell => /^Due(?: Date)?$/i.test(text(cell)));
      for (const row of grid.querySelectorAll('tr')) {
        const title = text(row.querySelector('[role="rowheader"]'));
        if (!title || title.length > 500) continue;
        const date = text(row.cells[dueIndex]).match(/^(\d{1,2})\/(\d{1,2})\/(20\d{2})\s+(\d{1,2}):(\d{2})\s*(AM|PM)$/i);
        if (!date || +date[4] < 1 || +date[4] > 12 || +date[5] > 59) { skipped++; continue; }
        const [, month, day, year, hour, minute, period] = date;
        const h = +hour % 12 + (period.toUpperCase() === 'PM' ? 12 : 0);
        const candidates = [4, 5].map(offset => new Date(Date.UTC(+year, +month - 1, +day, h + offset, +minute)))
          .filter(candidate => {
            const fields = Object.fromEntries(clock.formatToParts(candidate).map(({type,value}) => [type,+value]));
            return fields.year === +year && fields.month === +month && fields.day === +day && fields.hour === h && fields.minute === +minute;
          });
        if (candidates.length !== 1) { skipped++; continue; }
        if (events.has(title)) duplicates.add(title);
        events.set(title, {id:title, title, due:candidates[0].toISOString(), submitted:null, url:'https://www.aleks.com/'});
      }
    }
    for (const title of duplicates) { events.delete(title); skipped++; }
    if (!events.size) return null;
    return {version:1, source:'aleks', courseKey:course, course, events:[...events.values()],
      warning:'ALEKS 截止时间按纽约时区换算，请与课程页面核对。' + (skipped ? `已跳过 ${skipped} 项日期无法确认或名称重复的作业。` : '')};
  }
  function parse(doc, address, now=new Date()) {
    const url = new URL(address);
    if (url.protocol !== 'https:') return null;
    if (/(^|\.)aleks\.com$/.test(url.hostname)) return aleks(doc);
    if(url.hostname==='keenly.study' && /^\/tasks\/?$/.test(url.pathname))return keenly(doc,now);
    let source, courseKey, course, events = [], skipped = 0, warning = null;
    if (['gradescope.com','www.gradescope.com'].includes(url.hostname)) {
      const match = url.pathname.match(/^\/courses\/(\d+)\/?$/);
      const table = doc.querySelector('table#assignments-student-table') || [...doc.querySelectorAll('table')].find(t => /Assignments List/.test(text(t.querySelector('caption'))));
      if (!match || !table) return null;
      source = 'gradescope'; courseKey = match[1]; course = text(doc.querySelector('h1'));
      for (const row of table.querySelectorAll('tbody tr')) {
        const link = row.querySelector('th a[href*="/assignments/"], th button[data-assignment-id]');
        const id = link?.getAttribute('data-assignment-id') || link?.getAttribute('href')?.match(/\/assignments\/(\d+)/)?.[1];
        // Do not substitute release dates or late-submission cutoffs.
        const dueNodes = [...row.querySelectorAll('time.submissionTimeChart--dueDate[datetime]')].filter(n => !/^Late\b/i.test(n.getAttribute('aria-label') || text(n)));
        const dates = [...new Set(dueNodes.map(n => n.getAttribute('datetime')))];
        const raw = dates.length === 1 ? dates[0] : '';
        const exact = raw.match(/^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{2})(\d{2})$/);
        const due = exact ? iso(`${exact[1]}T${exact[2]}${exact[3]}:${exact[4]}`) : null;
        if (!id || !due) { skipped++; continue; }
        const status = text(row.querySelector('.submissionStatus--text'));
        const submitted = (/^Submitted\b/i.test(status) || /\/submissions\/\d+/.test(link.getAttribute('href') || '')) ? true : /^(No Submission|Not Submitted)\b/i.test(status) ? false : null;
        events.push({id,title:text(link),due,submitted,url:`https://www.gradescope.com/courses/${courseKey}/assignments/${id}`});
      }
    } else if (['webassign.net','www.webassign.net'].includes(url.hostname) && url.pathname === '/v4cgi/student.pl') {
      source = 'webassign';
      course = doc.title.replace(/\s+-\s+(Home|My Assignments)\s*\|\s*WebAssign.*$/i,'').trim();
      if (!course || course === doc.title && !/WebAssign/.test(doc.title)) return null;
      courseKey = course; // hashed by the native bridge; no session query is persisted
      const table = [...doc.querySelectorAll('table')].find(t => /DUE DATE/i.test(text(t)) && t.querySelector('a[href*="Assignment-Responses"]'));
      if (table) {
        for (const row of table.querySelectorAll('tr')) {
          const link = row.querySelector('a[href*="Assignment-Responses"]');
          if (!link) continue;
          const id = new URL(link.getAttribute('href'),url.origin).searchParams.get('dep');
          const dateText = [...row.querySelectorAll('td')].map(text).find(t => /\d{4} at .*\b(?:EDT|EST)\b/.test(t));
          const exact = dateText?.match(/(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), (\w+ \d{1,2}, \d{4}) at (\d{1,2}:\d{2} [AP]M) (EDT|EST)/);
          const due = exact ? iso(`${exact[1]} ${exact[2]} GMT${exact[3]==='EDT'?'-0400':'-0500'}`) : null;
          if (!/^\d+$/.test(id || '') || !due) { skipped++; continue; }
          events.push({id,title:text(link),due,submitted:null,url:`https://www.webassign.net/web/Student/Assignment-Responses/last?dep=${id}`});
        }
        warning = '仅覆盖当前作业列表；未显示的旧项目保留待核实。';
      } else {
        const element = doc.querySelector('[data-assignments]');
        if (!element) return null;
        let data; try { data = JSON.parse(element.getAttribute('data-assignments')); } catch { return null; }
        if (!Array.isArray(data.current_assignments) || !Array.isArray(data.past_assignments)) return null;
        for (const a of [...data.current_assignments,...data.past_assignments]) {
          const id = String(a.id), seconds = Number(a.due?.seconds);
          const due = a.due?.seconds != null && Number.isFinite(seconds) ? iso(seconds*1000) : null;
          if (!/^\d+$/.test(id) || !due || typeof a.name !== 'string') { skipped++; continue; }
          events.push({id,title:a.name,due,submitted:null,url:`https://www.webassign.net/web/Student/Assignment-Responses/last?dep=${id}`});
        }
        warning = '首页只提供部分作业；请打开 My Assignments 补充完整列表。';
      }
    } else return null;
    if (!course) return null;
    if (skipped) warning = `${skipped} 项缺少可确认的截止时间，已跳过；请在网站核实。${warning||''}`;
    return {version:1,source,courseKey,course,events,warning};
  }
  const api={parse};
  if(typeof module!=='undefined')module.exports=api;
  root.DDLParser=api;
})(globalThis);
