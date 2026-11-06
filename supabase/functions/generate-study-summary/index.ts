import { createClient } from "npm:@supabase/supabase-js@2";
const corsHeaders={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS"};
const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:{...corsHeaders,"Content-Type":"application/json; charset=utf-8"}});
function b64(bytes:Uint8Array){let s="";for(let i=0;i<bytes.length;i+=0x8000)s+=String.fromCharCode(...bytes.subarray(i,Math.min(i+0x8000,bytes.length)));return btoa(s)}
function outText(d:any){if(typeof d?.output_text==="string"&&d.output_text.trim())return d.output_text.trim();const a:string[]=[];for(const s of d?.steps||[])if(s.type==="model_output")for(const p of s.content||[])if(p.type==="text"&&typeof p.text==="string")a.push(p.text);return a.join("\n").trim()}
function clean(s:string){return s.replace(/^```(?:json)?\s*/i,"").replace(/\s*```$/i,"").trim()}
function sourcePage(ref:string):number|null{const m=String(ref||"").match(/(?:صفحة|page)\s*#?\s*(\d+)/i);return m?Number(m[1]):null}
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return reply({error:"استخدم POST فقط."},405);
 const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_ANON_KEY"),gemini=Deno.env.get("GEMINI_API_KEY");
 if(!url||!key||!gemini)return reply({error:"إعدادات الذكاء الاصطناعي غير مكتملة."},500);
 const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
 if(!token)return reply({error:"يجب تسجيل الدخول أولًا."},401);
 const sb=createClient(url,key,{global:{headers:{Authorization:`Bearer ${token}`}},auth:{persistSession:false,autoRefreshToken:false}});
 const au=await sb.auth.getUser(token); if(au.error||!au.data.user)return reply({error:"جلسة الدخول غير صالحة."},401);
 const {data:profile}=await sb.from("user_profiles").select("id,role,is_active").eq("id",au.data.user.id).maybeSingle();
 if(!profile||profile.is_active===false||profile.role!=="admin")return reply({error:"توليد الأسئلة متاح للمدير النشط فقط."},403);
 let summaryId="";
 try{
  const body=await req.json(); summaryId=String(body.summary_id||""); const path=String(body.pdf_path||""); const subject=String(body.subject||"المادة التدريبية").slice(0,150);
  const tf=Math.max(0,Number.parseInt(body.true_false_count,10)||0),mc=Math.max(0,Number.parseInt(body.mcq_count,10)||0),essay=Math.max(0,Number.parseInt(body.essay_count,10)||0);
  const batchNo=Number.parseInt(body.batch_no,10)||1; const total=tf+mc+essay; if(!summaryId||!path||!path.toLowerCase().endsWith(".pdf")||path.includes(".."))return reply({error:"بيانات الملخص أو ملف PDF غير صالحة."},400); if(!Number.isInteger(batchNo)||batchNo<1||batchNo>100)return reply({error:"رقم الجزء يجب أن يكون بين 1 و100."},400); if(!total)return reply({error:"حدد عدد الأسئلة المطلوب توليدها."},400); if(total>100)return reply({error:"الحد الأقصى 100 سؤال في الجزء الواحد."},400); if(tf>50||mc>50||essay>50)return reply({error:"عدد أي نوع من الأسئلة لا يمكن أن يتجاوز 50 في المجموعة."},400);
  await sb.from("study_summaries").update({ai_generation_status:"processing",ai_generation_error:null,source_pdf_path:path}).eq("id",summaryId);
  const signed=await sb.storage.from("study-summary-pdfs").createSignedUrl(path,600); if(signed.error||!signed.data?.signedUrl)throw Error("تعذرت قراءة ملف PDF المرفوع.");
  const pdf=await fetch(signed.data.signedUrl); if(!pdf.ok)throw Error("تعذر تنزيل ملف PDF."); const bytes=new Uint8Array(await pdf.arrayBuffer()); if(!bytes.length||bytes.length>15*1024*1024)throw Error("حجم ملف PDF غير صالح أو أكبر من 15 ميجابايت.");
  const priorResult=await sb.from("study_summary_questions").select("question_text").eq("summary_id",summaryId).neq("batch_no",batchNo); if(priorResult.error)throw priorResult.error; const priorQuestions=(priorResult.data||[]).map((q:any)=>String(q.question_text||"").trim()).filter(Boolean); const priorText=priorQuestions.length?priorQuestions.map((q:string,i:number)=>(i+1)+". "+q).join("\n"):"لا توجد أسئلة سابقة.";
  const prompt=`أنت مولّد أسئلة دقيق لمركز الأندلس. اقرأ ملف PDF المرفق فقط. أنت تولد الجزء رقم ${batchNo} من ملخص متعدد الأجزاء. المطلوب بالضبط ${tf} سؤال true_false و${mc} سؤال mcq و${essay} سؤال essay؛ الإجمالي ${total} سؤالًا. لا تقلل العدد ولا تتوقف قبل إكماله. اجعل السؤال والإجابة مختصرين لتستطيع إكمال العدد كله. لا تكرر الأسئلة ولا تخترع معلومات. ممنوع تكرار أو إعادة صياغة الأسئلة الموجودة في الأجزاء الأخرى: ${priorText}. أخرج JSON صحيحًا فقط بلا Markdown أو مقدمة أو خاتمة، وبمفتاح questions يحتوي العدد الكامل المطلوب. كل عنصر: {"type":"true_false|mcq|essay","question":"نص السؤال","options":[],"answer":"الإجابة","explanation":"","source_reference":""}. صح/خطأ: options بالضبط ["صح","خطأ"] وanswer "صح" أو "خطأ". mcq: أربعة اختيارات نصية وanswer يطابق اختيارًا واحدًا حرفيًا. essay: options مصفوفة فارغة وإجابة نموذجية موجزة. لا تضع فواصل زائدة ولا تترك سؤالًا ناقصًا. source_reference يجب أن يحتوي رقم صفحة PDF الفعلي الذي يدعم السؤال بصيغة "صفحة 12" مثلًا، اعتمادًا على ترقيم صفحات ملف PDF نفسه (أول صفحة في الملف هي صفحة 1). لا تخمن رقم الصفحة؛ إذا تعذر تحديد الصفحة بدقة اترك source_reference فارغًا. هذه المعلومة للمراجعة الإدارية فقط.`;
  const models=["gemini-3.5-flash-lite","gemini-2.5-flash-lite","gemini-2.5-flash"];
  let ad:any=null, lastError=""; let usedModel="";
  for(const model of models){
    let modelSucceeded=false;
    for(let attempt=0;attempt<2;attempt++){
      try{
        const ar=await fetch("https://generativelanguage.googleapis.com/v1beta/interactions",{method:"POST",headers:{"Content-Type":"application/json","x-goog-api-key":gemini},body:JSON.stringify({model,store:false,input:[{type:"text",text:prompt},{type:"document",data:b64(bytes),mime_type:"application/pdf"}]})});
        const result=await ar.json().catch(()=>({}));
        if(ar.ok){ad=result;usedModel=model;modelSucceeded=true;break;}
        lastError=String(result?.error?.message||("HTTP "+ar.status));
        const transient=ar.status===429||ar.status===500||ar.status===502||ar.status===503||ar.status===504;
        const modelUnavailable=ar.status===404||/high demand|overload|temporarily unavailable|model.*not found|not available/i.test(lastError);
        if(!transient&&!modelUnavailable)throw Error(lastError);
        if(attempt===0&&transient)await new Promise(resolve=>setTimeout(resolve,900));
        else break;
      }catch(err){lastError=err instanceof Error?err.message:String(err);if(attempt===1)break;}
    }
    if(modelSucceeded)break;
  }
  if(!ad)throw Error("تعذر توليد الأسئلة بسبب ضغط مؤقت على خدمة الذكاء الاصطناعي أو عدم توفر النموذج. جرب مرة أخرى بعد قليل. التفاصيل: "+lastError);
  let text=outText(ad); if(!text)throw Error("لم تُرجع خدمة الذكاء الاصطناعي أسئلة.");
  let parsed:any=null,raw:any[]=[],valid:any[]=[],selected:any[]=[];
  const normalizeQuestion=(s:string)=>String(s||"").normalize("NFKC").toLowerCase().replace(/[\u064B-\u065F\u0670]/g,"").replace(/[^\p{L}\p{N}]+/gu," ").trim();
  const validateOutput=(output:string)=>{
   let p:any=null;const cleaned=clean(output);
   try{p=JSON.parse(cleaned)}catch{
    const start=cleaned.indexOf("{"),end=cleaned.lastIndexOf("}");
    if(start>=0&&end>start){try{p=JSON.parse(cleaned.slice(start,end+1))}catch{}}
   }
   const arr=Array.isArray(p?.questions)?p.questions:[];
   const good=arr.filter((q:any)=>{if(!q||typeof q.question!=="string"||!q.question.trim()||typeof q.answer!=="string")return false;if(q.type==="mcq")return Array.isArray(q.options)&&q.options.length===4&&q.options.every((x:any)=>typeof x==="string")&&q.options.includes(q.answer);if(q.type==="true_false")return Array.isArray(q.options)&&q.options.length===2&&(q.answer==="صح"||q.answer==="خطأ");if(q.type==="essay")return Array.isArray(q.options)&&q.options.length===0&&q.answer.trim().length>0;return false});
   const seen=new Set<string>(priorQuestions.map(normalizeQuestion));
   const take=(type:string,count:number)=>{if(!count)return [];const out:any[]=[];for(const q of good.filter((x:any)=>x.type===type)){const key=normalizeQuestion(q.question);if(!key||seen.has(key))continue;seen.add(key);out.push(q);if(out.length>=count)break;}return out;};
   const chosen=[...take("true_false",tf),...take("mcq",mc),...take("essay",essay)];
   return {p,arr,good,chosen};
  };
  let checked=validateOutput(text);
  for(let repair=0;repair<4&&checked.chosen.length!==total;repair++){
   const repairModel=models[(repair+1)%models.length]||usedModel||"gemini-2.5-flash";
   const repairPrompt=`أعد توليد الجزء ${batchNo} كاملًا من ملف PDF نفسه. ردك السابق لم يحقق العدد أو التنسيق أو التميز المطلوب. المطلوب بالضبط ${tf} true_false و${mc} mcq و${essay} essay، الإجمالي ${total}. رد JSON فقط مع ${total} سؤالًا كاملًا؛ أسئلة وإجابات مختصرة. ممنوع تكرار أو إعادة صياغة الأسئلة التالية الموجودة في المجموعة الأخرى: ${priorText}. القواعد: true_false options ["صح","خطأ"] والإجابة واحدة منهما؛ mcq أربعة اختيارات والإجابة تطابق اختيارًا حرفيًا؛ essay options []. source_reference يجب أن يحتوي رقم صفحة PDF الفعلي بصيغة "صفحة 12" مثلًا؛ لا تخمن، واتركه فارغًا إن لم تتأكد. المخطط: {"questions":[{"type":"true_false|mcq|essay","question":"...","options":[],"answer":"...","explanation":"","source_reference":""}]}`;
   try{
    const rr=await fetch("https://generativelanguage.googleapis.com/v1beta/interactions",{method:"POST",headers:{"Content-Type":"application/json","x-goog-api-key":gemini},body:JSON.stringify({model:repairModel,store:false,input:[{type:"text",text:repairPrompt},{type:"document",data:b64(bytes),mime_type:"application/pdf"}]})});
    const rd=await rr.json().catch(()=>({}));
    if(rr.ok){const retryText=outText(rd);if(retryText){text=retryText;checked=validateOutput(text);}}
    else lastError=String(rd?.error?.message||("HTTP "+rr.status));
   }catch(err){lastError=err instanceof Error?err.message:String(err);}
  }
  parsed=checked.p;raw=checked.arr;valid=checked.good;selected=checked.chosen;
  if(selected.length!==total)throw Error(`تعذر إكمال العدد المطلوب بعد أربع محاولات إصلاح إضافية. وصلنا إلى ${selected.length} سؤالًا صالحًا من أصل ${total}. لم تُحفظ الدفعة الناقصة؛ جرّب مرة أخرى أو قلّل طول المادة/عدد الأسئلة.`);
  const del=await sb.from("study_summary_questions").delete().eq("summary_id",summaryId).eq("ai_generated",true).eq("batch_no",batchNo);if(del.error)throw del.error;
  const rows=selected.map((q:any,i:number)=>({summary_id:summaryId,question_text:q.question.trim(),answer_text:q.answer.trim(),explanation:String(q.explanation||"").trim(),order_num:i+1,question_type:q.type,options:q.options||[],ai_generated:true,is_approved:false,is_selected:false,source_reference:String(q.source_reference||"").trim(),source_page:sourcePage(String(q.source_reference||"")),batch_no:batchNo}));
  const ins=await sb.from("study_summary_questions").insert(rows);if(ins.error)throw ins.error;
  const counts=await sb.from("study_summary_questions").select("id",{count:"exact",head:true}).eq("summary_id",summaryId);if(counts.error)throw counts.error;
  const saved=await sb.from("study_summaries").update({ai_generation_status:"ready",ai_generation_error:null,generated_question_count:counts.count??selected.length,source_pdf_path:path}).eq("id",summaryId);if(saved.error)throw saved.error;
  return reply({success:true,batchNo,generatedCount:selected.length,totalQuestionCount:counts.count??selected.length,counts:{true_false:selected.filter((q:any)=>q.type==="true_false").length,mcq:selected.filter((q:any)=>q.type==="mcq").length,essay:selected.filter((q:any)=>q.type==="essay").length},message:"تم توليد أسئلة المجموعة مع الحفاظ على المجموعة الأخرى."});
 }catch(e){const msg=e instanceof Error?e.message:String(e);if(summaryId)await sb.from("study_summaries").update({ai_generation_status:"failed",ai_generation_error:msg}).eq("id",summaryId);return reply({error:msg},500)}
});