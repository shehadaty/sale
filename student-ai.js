/* Compatibility loader: the current student AI lives in student-ai-assistant.js. */
(function(){
  'use strict';
  if (window.__academyStudentAiAssistantLoader) return;
  window.__academyStudentAiAssistantLoader = true;
  function load(){
    if (window.__academyStudentAiAssistantLoaded || document.querySelector('script[data-academy-student-ai-assistant]')) return;
    const s=document.createElement('script');
    s.src='./student-ai-assistant.js?v=20261108';
    s.dataset.academyStudentAiAssistant='1';
    s.defer=true;
    document.head.appendChild(s);
  }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',load,{once:true});
  else load();
})();
