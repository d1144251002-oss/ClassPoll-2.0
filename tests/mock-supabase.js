(function(){
 const teacher={id:'11111111-1111-4111-8111-111111111111',email:'qa-teacher@example.invalid',is_anonymous:false};
 const anonymousUser={id:'77777777-7777-4777-8777-777777777777',is_anonymous:true};
 let current=localStorage.getItem('__mock_student_logged')?anonymousUser:
  (localStorage.getItem('__mock_teacher_logged')?teacher:
  (location.pathname.endsWith('/student.html')||localStorage.getItem('__mock_no_auto')||localStorage.getItem('__mock_teacher_signedout')?null:teacher));
 const room={id:'22222222-2222-4222-8222-222222222222',title:'資料結構測試班',code:'QA2026',owner_id:teacher.id,is_active:true,created_at:'2026-10-15T00:00:00Z'};
 const dashboard={rooms:[
  {...room,role:'owner',students:2,active_students:2,present_today:1,questions:3,live_questions:1,answers:3,recent_errors:0},
  {...room,id:'33333333-3333-4333-8333-333333333333',code:'TEST02',title:'只讀授權班',role:'auditor',students:3,active_students:3,present_today:2,questions:5,live_questions:0,answers:9,recent_errors:1}
 ]};
 const student={id:'44444444-4444-4444-8444-444444444444',room_id:room.id,student_no:'QA123',display_name:'王同學',is_active:true,last_seen:null};
 const question={id:'88888888-8888-4888-8888-888888888888',room_id:room.id,
  prompt:'2+2 等於多少？',options:['3','4'],points:5,status:'closed',
  allow_changes:false,created_at:'2026-10-15T00:00:00Z',published_at:'2026-10-15T00:00:00Z',ends_at:null};
 const records={cp2_rooms:[room],cp2_students:[student],cp2_questions:[question],
  cp2_answer_keys:[{question_id:question.id,correct_index:1}],
  cp2_votes:[{id:'99999999-9999-4999-8999-999999999999',question_id:question.id,
   student_id:student.id,choice:1,created_at:'2026-10-15T00:10:00Z',updated_at:'2026-10-15T00:10:00Z'}],
  cp2_attendance:[],cp2_bank:[],cp2_audit:[],cp2_errors:[]};
 const chain=table=>{
  const data=records[table]||[];
  return {select(){return this},eq(){return this},in(){return this},order(){return this},range(){return this},
   limit(){return this},maybeSingle:async()=>({data:table==='cp2_teachers'?{user_id:teacher.id}:null,error:null}),
   then(resolve,reject){return Promise.resolve({data,error:null}).then(resolve,reject)}};
 };
 const rpc=async(name,args)=>{
  let data=null;
  if(name==='cp2_platform_overview')data=dashboard;
  else if(name==='cp2_role_list'||name==='cp2_platform_audit')data=[];
  else if(name==='cp2_join')data=[{student_id:'44444444-4444-4444-8444-444444444444',room_id:room.id,display_name:'王同學',room_title:room.title}];
  else if(name==='cp2_resume')data=localStorage.getItem('classpoll-2-last-room')?[{student_id:student.id,room_id:room.id,display_name:student.display_name,room_title:room.title}]:[];
  else if(name==='cp2_qna_list')data=current?.is_anonymous?[]:[{
   id:'55555555-5555-4555-8555-555555555555',student_no:'QA123',display_name:'王同學',
   body:'資料結構是什麼？',answer:null,status:'open',created_at:'2026-10-15T00:00:00Z'
  }];
  else if(name==='cp2_qna_post')data='66666666-6666-4666-8666-666666666666';
  return {data,error:null};
 };
 const db={auth:{
   getSession:async()=>({data:{session:current?{user:current}:null},error:null}),
   signInAnonymously:async()=>{current=anonymousUser;localStorage.setItem('__mock_student_logged','1');return {data:{user:current,session:{user:current}},error:null}},
   signInWithPassword:async()=>{current=teacher;localStorage.setItem('__mock_teacher_logged','1');localStorage.removeItem('__mock_teacher_signedout');return {data:{user:current,session:{user:current}},error:null}},
   signOut:async()=>{if(current?.is_anonymous)localStorage.removeItem('__mock_student_logged');else {localStorage.removeItem('__mock_teacher_logged');localStorage.setItem('__mock_teacher_signedout','1');}current=null;return {error:null}},
   onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}})
  },
  from:chain,rpc,
  channel:()=>({on(){return this},subscribe(){return this}}),
  removeChannel:async()=>null,realtime:{connect(){}}
 };
 window.supabase={createClient:()=>db};window.__classpollMock=db;
})();
