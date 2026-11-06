-- ============================================================================
-- Migration 3: Storage — البوكتات والسياسات.
-- مصدر الإعدادات: schema_storage.sql + ملفات SQL القديمة في الأصل + استخدام الواجهة.
--
-- ⛔ لم تُنقل هذه السياسات من الأصل لأنها تمنح دور anon (أي زائر) قراءة ورفع وتعديل وحذف
--    صور الطلاب وملفاتهم وصور المعرض وقوالب الشهادات:
--      allow read / allow upload / allow delete / andalus_public_read|insert|update|delete
--    (سياسات Postgres تُجمع بـ OR، فكانت تلغي أثر السياسات الأشد.)
--
-- قرارات هذه الـ Migration (قابلة للتعديل):
--   * student-photos و student-files: خاصة (private). الواجهة تستخدم حاليًا getPublicUrl لهما،
--     وسيُستبدل بـ createSignedUrl عند نقل الواجهة (المرحلة 3). لا واجهة منشورة بعد فلا شيء يتعطل.
--   * gallery-photos و certificate-templates: عامة للقراءة عبر الرابط (معرض وقوالب شهادات بلا بيانات شخصية)،
--     بدون سياسة SELECT لـ anon، فلا يمكن سرد محتوياتها، والكتابة للموظفين فقط.
--   * أحجام الملفات وأنواعها: study-summary-pdfs و weekly-quiz-face-audit من الأصل؛ الباقي قيم معقولة
--     (الأصل غير معروف) تُراجَع.
-- لم تُجرَّب على قاعدة فعلية بعد.
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
  ('student-photos',         'student-photos',         false, 5242880,  ARRAY['image/jpeg','image/png','image/webp']),
  ('student-files',          'student-files',          false, 15728640, ARRAY['application/pdf','image/jpeg','image/png','image/webp']),
  ('gallery-photos',         'gallery-photos',         true,  5242880,  ARRAY['image/jpeg','image/png','image/webp']),
  ('certificate-templates',  'certificate-templates',  true,  5242880,  ARRAY['image/jpeg','image/png','image/webp']),
  ('exam-materials',         'exam-materials',         false, 15728640, NULL),
  ('study-summary-pdfs',     'study-summary-pdfs',     false, 15728640, ARRAY['application/pdf','image/jpeg','image/png','image/webp']),
  ('weekly-quiz-face-audit', 'weekly-quiz-face-audit', false, 1048576,  ARRAY['image/jpeg'])
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- A) سياسات منقولة حرفيًا من الأصل (سليمة): امتحانات، ملخصات، تدقيق المسابقة، حذف الأدمن.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Exam materials staff delete" ON storage.objects;
CREATE POLICY "Exam materials staff delete" ON "storage"."objects" FOR DELETE TO "authenticated" USING (("bucket_id" = 'exam-materials'::"text"));

DROP POLICY IF EXISTS "Exam materials staff read" ON storage.objects;
CREATE POLICY "Exam materials staff read" ON "storage"."objects" FOR SELECT TO "authenticated" USING (("bucket_id" = 'exam-materials'::"text"));

DROP POLICY IF EXISTS "Exam materials staff upload" ON storage.objects;
CREATE POLICY "Exam materials staff upload" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK (("bucket_id" = 'exam-materials'::"text"));

DROP POLICY IF EXISTS "study summary pdf admin delete" ON storage.objects;
CREATE POLICY "study summary pdf admin delete" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'study-summary-pdfs'::"text") AND "public"."is_admin"()));

DROP POLICY IF EXISTS "study summary pdf admin read" ON storage.objects;
CREATE POLICY "study summary pdf admin read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'study-summary-pdfs'::"text") AND "public"."is_admin"()));

DROP POLICY IF EXISTS "study summary pdf admin update" ON storage.objects;
CREATE POLICY "study summary pdf admin update" ON "storage"."objects" FOR UPDATE TO "authenticated" USING ((("bucket_id" = 'study-summary-pdfs'::"text") AND "public"."is_admin"())) WITH CHECK ((("bucket_id" = 'study-summary-pdfs'::"text") AND "public"."is_admin"()));

DROP POLICY IF EXISTS "study summary pdf admin upload" ON storage.objects;
CREATE POLICY "study summary pdf admin upload" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'study-summary-pdfs'::"text") AND "public"."is_admin"()));

DROP POLICY IF EXISTS "study summary proof admin read" ON storage.objects;
CREATE POLICY "study summary proof admin read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'study-summary-pdfs'::"text") AND "public"."is_admin"()));

DROP POLICY IF EXISTS "study summary proof student upload" ON storage.objects;
CREATE POLICY "study summary proof student upload" ON "storage"."objects" FOR INSERT TO "authenticated", "anon" WITH CHECK ((("bucket_id" = 'study-summary-pdfs'::"text") AND ("split_part"("name", '/'::"text", 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::"text") AND ("split_part"("name", '/'::"text", 2) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::"text") AND "public"."can_upload_study_summary_payment_proof"("split_part"("name", '/'::"text", 1), "split_part"("name", '/'::"text", 2))));

DROP POLICY IF EXISTS "weekly_quiz_audit_admin_read" ON storage.objects;
CREATE POLICY "weekly_quiz_audit_admin_read" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'weekly-quiz-face-audit'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."user_profiles" "p"
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."role" = 'admin'::"text") AND ("p"."is_active" = true))))));

DROP POLICY IF EXISTS "weekly_quiz_audit_upload_anon" ON storage.objects;
CREATE POLICY "weekly_quiz_audit_upload_anon" ON "storage"."objects" FOR INSERT TO "anon" WITH CHECK ((("bucket_id" = 'weekly-quiz-face-audit'::"text") AND "public"."can_upload_weekly_quiz_audit"("name")));

DROP POLICY IF EXISTS "weekly_quiz_audit_upload_auth" ON storage.objects;
CREATE POLICY "weekly_quiz_audit_upload_auth" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'weekly-quiz-face-audit'::"text") AND "public"."can_upload_weekly_quiz_audit"("name")));

DROP POLICY IF EXISTS "files_delete_admin" ON storage.objects;
CREATE POLICY "files_delete_admin" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'student-files'::"text") AND "public"."is_admin"()));

DROP POLICY IF EXISTS "photos_delete_admin" ON storage.objects;
CREATE POLICY "photos_delete_admin" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'student-photos'::"text") AND "public"."is_admin"()));

-- ---------------------------------------------------------------------------
-- B) سياسات معاد كتابتها: كانت للمستخدم المسجّل أيًا كان؛ الآن لمستخدم فعّال فقط.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "photos_read_authenticated"   ON storage.objects;
DROP POLICY IF EXISTS "photos_insert_authenticated" ON storage.objects;
DROP POLICY IF EXISTS "photos_update_authenticated" ON storage.objects;
CREATE POLICY "photos_read_authenticated"   ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'student-photos' AND (SELECT public.is_active_user()));
CREATE POLICY "photos_insert_authenticated" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'student-photos' AND (SELECT public.is_active_user()));
CREATE POLICY "photos_update_authenticated" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'student-photos' AND (SELECT public.is_active_user()))
  WITH CHECK (bucket_id = 'student-photos' AND (SELECT public.is_active_user()));

DROP POLICY IF EXISTS "files_read_authenticated"   ON storage.objects;
DROP POLICY IF EXISTS "files_insert_authenticated" ON storage.objects;
DROP POLICY IF EXISTS "files_update_authenticated" ON storage.objects;
CREATE POLICY "files_read_authenticated"   ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'student-files' AND (SELECT public.is_active_user()));
CREATE POLICY "files_insert_authenticated" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'student-files' AND (SELECT public.is_active_user()));
CREATE POLICY "files_update_authenticated" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'student-files' AND (SELECT public.is_active_user()))
  WITH CHECK (bucket_id = 'student-files' AND (SELECT public.is_active_user()));

-- ---------------------------------------------------------------------------
-- C) جديد: معرض الصور وقوالب الشهادات (القراءة عبر الرابط العام، بلا سرد لـ anon).
--    قوالب الشهادات: الرفع للأدمن فقط، متسق مع Migration 2.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "gallery_staff_read"   ON storage.objects;
DROP POLICY IF EXISTS "gallery_staff_insert" ON storage.objects;
DROP POLICY IF EXISTS "gallery_staff_update" ON storage.objects;
DROP POLICY IF EXISTS "gallery_admin_delete" ON storage.objects;
CREATE POLICY "gallery_staff_read"   ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'gallery-photos' AND (SELECT public.is_active_user()));
CREATE POLICY "gallery_staff_insert" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'gallery-photos' AND (SELECT public.is_active_user()));
CREATE POLICY "gallery_staff_update" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'gallery-photos' AND (SELECT public.is_active_user()))
  WITH CHECK (bucket_id = 'gallery-photos' AND (SELECT public.is_active_user()));
CREATE POLICY "gallery_admin_delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'gallery-photos' AND (SELECT public.is_admin()));

DROP POLICY IF EXISTS "cert_templates_admin_read"   ON storage.objects;
DROP POLICY IF EXISTS "cert_templates_admin_insert" ON storage.objects;
DROP POLICY IF EXISTS "cert_templates_admin_update" ON storage.objects;
DROP POLICY IF EXISTS "cert_templates_admin_delete" ON storage.objects;
CREATE POLICY "cert_templates_admin_read"   ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'certificate-templates' AND (SELECT public.is_active_user()));
CREATE POLICY "cert_templates_admin_insert" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'certificate-templates' AND (SELECT public.is_admin()));
CREATE POLICY "cert_templates_admin_update" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'certificate-templates' AND (SELECT public.is_admin()))
  WITH CHECK (bucket_id = 'certificate-templates' AND (SELECT public.is_admin()));
CREATE POLICY "cert_templates_admin_delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'certificate-templates' AND (SELECT public.is_admin()));
