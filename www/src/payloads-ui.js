export async function initPayloadUi(runtime=null) {
  if(document.getElementById("ps5-payloads"))return;
  const style=document.createElement("style");
  style.textContent="#ps5-payloads{margin:24px 0;padding:18px;border:1px solid #555;border-radius:10px;font:18px/1.5 sans-serif;max-width:950px;color:#eee;background:#121212}#ps5-payloads [hidden]{display:none!important}#ps5-payloads h2{margin:20px 0 10px;font-size:22px}#ps5-payloads button,#ps5-payloads input{font:inherit}#ps5-payloads button{padding:10px 14px;margin:4px;border:1px solid #777;border-radius:6px;background:#292929;color:#fff;cursor:pointer}#ps5-payloads button:focus,#ps5-payloads input:focus{outline:3px solid #75bfff}#ps5-payloads button:disabled{opacity:.5;cursor:default}#ps5-payloads input[type=password]{display:block;box-sizing:border-box;width:100%;padding:10px;margin:6px 0 14px;background:#222;color:#fff;border:1px solid #777}#ps5-payloads input[type=checkbox]{width:22px;height:22px;vertical-align:middle}#ps5-payloads table{border-collapse:collapse;width:100%}#ps5-payloads td,#ps5-payloads th{text-align:left;padding:8px;border-bottom:1px solid #444}#ps5-payloads .payload-name{overflow-wrap:anywhere}.payload-scroll{overflow-x:auto}.payload-status{white-space:pre-wrap}.payload-status[data-error=true]{color:#ff9696}";
  document.head.appendChild(style);
  const root=document.createElement("section");root.id="ps5-payloads";
  root.innerHTML='<button type="button" id="payload-toggle" aria-expanded="false" aria-controls="payload-content">Дополнительные нагрузки</button><div id="payload-content" hidden><p id="payload-runtime"></p><form id="payload-login" hidden><label for="payload-token">Код доступа с роутера</label><input id="payload-token" type="password" autocomplete="off"><button type="submit">Открыть управление</button></form><div id="payload-manager" hidden><p>Добавьте ELF-файлы на роутер, выберите их для запуска и сохраните автозапуск.</p><form id="payload-upload"><label for="payload-file">Добавить ELF-файл (до 8 МиБ)</label><input id="payload-file" type="file" accept=".elf"><button type="submit">Загрузить на роутер</button></form><h2>Файлы в папке роутера</h2><p id="payload-empty">Папка пока пуста. Загрузите ELF-файл через форму выше.</p><div class="payload-scroll"><table id="payload-table"><thead><tr><th>Автозапуск</th><th>Файл</th><th>Размер</th><th>Порядок и запуск</th></tr></thead><tbody id="payload-files"></tbody></table></div><button type="button" id="payload-save">Сохранить автозапуск</button><button type="button" id="payload-run" data-needs-runtime>Запустить отмеченные сейчас</button><button type="button" id="payload-refresh">Обновить список</button></div><p id="payload-status" class="payload-status" role="status" aria-live="polite"></p></div>';
  document.body.appendChild(root);
  const find=(id)=>root.querySelector("#payload-"+id),rows=find("files"),status=find("status"),login=find("login"),manager=find("manager");
  let token="",busy=false;
  find("runtime").textContent=runtime?"ELF loader готов. Можно запускать выбранные файлы на PS5.":"Список файлов доступен. Запуск на PS5 откроется после запуска ELF loader.";
  function message(text,failed=false){status.textContent=text;status.dataset.error=String(failed);}
  function setBusy(value){busy=value;root.querySelectorAll("button,input").forEach((el)=>{if(el.id!=="payload-toggle")el.disabled=value||(!runtime&&el.hasAttribute("data-needs-runtime"));});}
  async function api(action,options={}) {
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),70000);
    try {
      const headers=Object.assign({},options.headers||{},{"X-PS5-Request":"1"});
      if(token)headers.Authorization="Bearer "+token;
      const response=await fetch("cgi-bin/payloads?action="+action,Object.assign({},options,{headers,cache:"no-store",signal:controller.signal}));
      const data=await response.json();
      if(!response.ok){const error=new Error(data.error||"Ошибка HTTP "+response.status);error.status=response.status;throw error;}
      return data;
    } finally {clearTimeout(timer);}
  }
  function selected(){return Array.from(rows.children).filter((row)=>row.querySelector("input").checked).map((row)=>row.dataset.name);}
  function render(data,keep=null) {
    const order=[...data.autoload,...data.files.map((f)=>f.name).filter((n)=>!data.autoload.includes(n))];rows.replaceChildren();
    for(const name of order) {
      const file=data.files.find((item)=>item.name===name);if(!file)continue;
      const row=document.createElement("tr");row.dataset.name=name;
      const checkCell=document.createElement("td"),check=document.createElement("input");
      check.type="checkbox";check.checked=keep?keep.includes(name):data.autoload.includes(name);
      check.setAttribute("aria-label","Автозагрузка "+name);checkCell.appendChild(check);
      const nameCell=document.createElement("td");nameCell.className="payload-name";nameCell.textContent=name;
      const sizeCell=document.createElement("td");sizeCell.textContent=(file.size/1024/1024).toFixed(2)+" МиБ";
      const actionCell=document.createElement("td");
      for(const [label,direction] of [["↑",-1],["↓",1]]) {
        const button=document.createElement("button");button.type="button";button.textContent=label;
        button.setAttribute("aria-label",(direction<0?"Выше ":"Ниже ")+name);
        button.addEventListener("click",()=>{if(busy)return;if(direction<0&&row.previousElementSibling)rows.insertBefore(row,row.previousElementSibling);if(direction>0&&row.nextElementSibling)rows.insertBefore(row.nextElementSibling,row);});
        actionCell.appendChild(button);
      }
      const run=document.createElement("button");run.type="button";run.textContent="Запустить";
      run.setAttribute("data-needs-runtime","");run.disabled=!runtime;
      run.addEventListener("click",()=>operation(()=>runFiles([name])));actionCell.appendChild(run);
      row.append(checkCell,nameCell,sizeCell,actionCell);rows.appendChild(row);
    }
    find("empty").hidden=data.files.length>0;find("table").hidden=data.files.length===0;setBusy(busy);
  }
  async function refresh(keep=null){render(await api("list"),keep);login.hidden=true;manager.hidden=false;}
  async function save(names){await api("manifest",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(names)});}
  async function runFiles(names) {
    if(!runtime)throw new Error("ELF loader на PS5 ещё не запущен.");
    if(!names.length)throw new Error("Сначала отметьте нагрузки.");
    message("Отправка на PS5: "+names.join(", ")+"…");
    const result=await runtime.run(names);
    if(result.failed.length)throw new Error("Не удалось отправить: "+result.failed.join(", ")+". Подробности в журнале.");
    message("Отправлено на PS5: "+result.sent.join(", ")+".");
  }
  async function operation(work) {
    if(busy)return;setBusy(true);
    try{await work();}
    catch(error){if(error.status===401){login.hidden=false;manager.hidden=true;}message(error.name==="AbortError"?"Истекло время ожидания. Обновите список файлов перед повторной попыткой.":error.message,true);}
    finally{setBusy(false);}
  }
  find("toggle").addEventListener("click",()=>{const content=find("content");content.hidden=!content.hidden;find("toggle").setAttribute("aria-expanded",String(!content.hidden));});
  login.addEventListener("submit",(event)=>{event.preventDefault();operation(async()=>{token=find("token").value.trim();if(!token)throw new Error("Введите код доступа из SSH.");await refresh();find("token").value="";message("Управление открыто.");});});
  find("upload").addEventListener("submit",(event)=>{event.preventDefault();operation(async()=>{const file=find("file").files[0];if(!file)throw new Error("Сначала выберите ELF-файл.");if(!/^[A-Za-z0-9][A-Za-z0-9_.-]*\.elf$/.test(file.name)||file.name.length>128)throw new Error("Недопустимое имя ELF-файла.");if(file.size<4||file.size>8388608)throw new Error("Размер ELF должен быть от 4 байт до 8 МиБ.");if(!token)throw Object.assign(new Error("Введите код доступа с роутера."),{status:401});const keep=selected();await api("upload&filename="+encodeURIComponent(file.name),{method:"POST",headers:{"Content-Type":"application/octet-stream"},body:file});find("file").value="";await refresh(keep);message("Файл добавлен. Для автозапуска отметьте его и сохраните список.");});});
  find("save").addEventListener("click",()=>operation(async()=>{await save(selected());message("Список и порядок автозапуска сохранены.");}));
  find("run").addEventListener("click",()=>operation(()=>runFiles(selected())));
  find("refresh").addEventListener("click",()=>operation(async()=>{await refresh();message("Список файлов обновлён.");}));
  await operation(async()=>{await refresh();message("Управление нагрузками готово.");});
}
