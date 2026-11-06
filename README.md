# نظام إدارة الأكاديميات (White Label)

واجهة ثابتة (بدون build) تعمل فوق Supabase. 

## الربط بقاعدة بيانات
الملف الوحيد المسؤول عن الاتصال: `config.js` (عنوان المشروع + Publishable key).
ممنوع وضع `secret` أو `service_role` في أي ملف واجهة.

## قاعدة البيانات
كل التغييرات عبر `supabase/migrations` (ملفات مرتبة)، وتُطبَّق بـ `supabase db push --linked`.
