// Shared parsing and strong, local-only classroom backup encryption.
export function parseRosterCSV(text) {
 const input=String(text??'').replace(/^\uFEFF/,'');const rows=[];let fields=[],field='',inQuotes=false;
 for(let i=0;i<input.length;i++){
  const c=input[i];
  if(inQuotes){
   if(c==='"'&&input[i+1]==='"'){field+='"';i++;}
   else if(c==='"'){inQuotes=false;}
   else field+=c;
  }else if(c==='"'&&field===''){inQuotes=true;}
  else if(c===','){fields.push(field.trim());field='';}
  else if(c==='\n'||c==='\r'){
   if(c==='\r'&&input[i+1]==='\n')i++;
   fields.push(field.trim());field='';
   if(fields.some(v=>v!==''))rows.push(fields);
   fields=[];
  }else field+=c;
 }
 if(inQuotes)throw Error('CSV 引號未關閉');
 fields.push(field.trim());if(fields.some(v=>v!==''))rows.push(fields);
 if(rows.length&&['學號','student_no','student number'].includes(rows[0][0]?.toLowerCase()))rows.shift();
 if(!rows.length)throw Error('請至少輸入一位學生');
 if(rows.length>200)throw Error('一次最多 200 名學生');
 const seen=new Set();
 return rows.map((fields,i)=>{
  const student_no=fields[0]?.trim()||'',display_name=fields[1]?.trim()||'';
  if(fields.length!==2||!student_no||!display_name||student_no.length>40||display_name.length>80)
   throw Error('第 '+(i+1)+' 行格式不正確，請使用「學號,姓名」');
  if(seen.has(student_no))throw Error('匯入資料內學號重複：'+student_no);
  seen.add(student_no);return {student_no,display_name};
 });
}
function bytesToBase64(bytes){
 let s='';for(const b of bytes)s+=String.fromCharCode(b);
 return btoa(s);
}
function base64ToBytes(encoded){
 const bin=atob(encoded);return Uint8Array.from(bin,c=>c.charCodeAt(0));
}
export async function encryptBackup(snapshot,passphrase) {
 if(typeof passphrase!=='string'||passphrase.length<12)throw Error('備份密碼至少需要 12 個字元');
 if(!globalThis.crypto?.subtle)throw Error('此瀏覽器不支援 Web Crypto，無法安全匯出');
 const enc=new TextEncoder(),salt=crypto.getRandomValues(new Uint8Array(16)),iv=crypto.getRandomValues(new Uint8Array(12));
 const keyMaterial=await crypto.subtle.importKey('raw',enc.encode(passphrase),'PBKDF2',false,['deriveKey']);
 const key=await crypto.subtle.deriveKey({name:'PBKDF2',salt,iterations:310000,hash:'SHA-256'},keyMaterial,
  {name:'AES-GCM',length:256},false,['encrypt']);
 const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:enc.encode('ClassPoll room backup v1')},
  key,enc.encode(JSON.stringify(snapshot)));
 return {
  format:'classpoll-encrypted-v1',algorithm:'AES-256-GCM',kdf:'PBKDF2-SHA256',iterations:310000,
  salt:bytesToBase64(salt),iv:bytesToBase64(iv),payload:bytesToBase64(new Uint8Array(ciphertext))
 };
}
export async function decryptBackup(envelope,passphrase){
 if(envelope?.format!=='classpoll-encrypted-v1'||envelope.algorithm!=='AES-256-GCM'||
   envelope.kdf!=='PBKDF2-SHA256'||envelope.iterations!==310000)throw Error('備份格式不受支援');
 if(typeof passphrase!=='string'||passphrase.length<12)throw Error('備份密碼不正確');
 try{
  const enc=new TextEncoder(),keyMaterial=await crypto.subtle.importKey('raw',enc.encode(passphrase),'PBKDF2',false,['deriveKey']);
  const key=await crypto.subtle.deriveKey({name:'PBKDF2',salt:base64ToBytes(envelope.salt),iterations:310000,hash:'SHA-256'},
   keyMaterial,{name:'AES-GCM',length:256},false,['decrypt']);
  const plain=await crypto.subtle.decrypt({name:'AES-GCM',iv:base64ToBytes(envelope.iv),
   additionalData:enc.encode('ClassPoll room backup v1')},key,base64ToBytes(envelope.payload));
  const decoded=JSON.parse(new TextDecoder().decode(plain));
  if(decoded?.format!=='classpoll-room-backup-v1')throw Error('已解密，但內容不是支援的教室備份');
  return decoded;
 }catch(e){throw Error('解密失敗：密碼錯誤、檔案損毀或資料格式不正確');}
}
