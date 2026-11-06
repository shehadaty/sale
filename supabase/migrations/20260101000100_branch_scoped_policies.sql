-- ============================================================================
-- Migration 2: عزل الفروع في 4 جداول كانت مفتوحة لأي مستخدم مسجّل (USING true).
-- السبب: شرط «الموظف لا يتجاوز صلاحيات فرعه». مثبت من نص السياسات في الأصل.
-- المنطق مطابق لدالة student_in_user_branch الموجودة: الأدمن أو فرع 'الكل' يرون كل
-- شيء، وغيرهم يرون فرعهم فقط. المستخدم غير الفعّال لا يرى شيئًا (get_user_branch = NULL).
-- ملاحظة: القيمة 'الكل' ثابتة هنا لأنها ثابتة في الدوال الأصلية؛ ستُستبدل في
-- Migration لاحقة عند بناء جدول branches (مرحلة White Label).
-- لم تُجرَّب على قاعدة فعلية بعد: تُطبَّق على المشروع الجديد ثم تُختبر بحسابات تجريبية.
-- ============================================================================

-- 1) schedule_sessions: لها عمود branch (NOT NULL) -> عزل كامل لكل العمليات
DROP POLICY IF EXISTS "schedule_sessions_all_authenticated" ON public.schedule_sessions;
CREATE POLICY "schedule_sessions_branch_scoped" ON public.schedule_sessions
  FOR ALL TO authenticated
  USING (
    (SELECT public.is_admin())
    OR (SELECT public.get_user_branch()) = 'الكل'
    OR branch = (SELECT public.get_user_branch())
  )
  WITH CHECK (
    (SELECT public.is_admin())
    OR (SELECT public.get_user_branch()) = 'الكل'
    OR branch = (SELECT public.get_user_branch())
  );

-- 2) tasks: branch اختياري. المهمة بلا فرع أو التي أنشأها المستخدم تبقى ظاهرة له.
DROP POLICY IF EXISTS "tasks_all_authenticated" ON public.tasks;
CREATE POLICY "tasks_branch_scoped" ON public.tasks
  FOR ALL TO authenticated
  USING (
    (SELECT public.is_admin())
    OR (SELECT public.get_user_branch()) = 'الكل'
    OR branch IS NULL
    OR branch = (SELECT public.get_user_branch())
    OR created_by = (SELECT auth.uid())
  )
  WITH CHECK (
    (SELECT public.is_admin())
    OR (SELECT public.get_user_branch()) = 'الكل'
    OR branch IS NULL
    OR branch = (SELECT public.get_user_branch())
    OR created_by = (SELECT auth.uid())
  );

-- 3) expenses: القراءة والإضافة بحدود الفرع. تعديل/حذف الأدمن كما هو (سياسة admin modify باقية).
DROP POLICY IF EXISTS "expenses read all" ON public.expenses;
CREATE POLICY "expenses read branch scoped" ON public.expenses
  FOR SELECT TO authenticated
  USING (
    (SELECT public.is_admin())
    OR (SELECT public.get_user_branch()) = 'الكل'
    OR branch = (SELECT public.get_user_branch())
  );

DROP POLICY IF EXISTS "expenses insert own" ON public.expenses;
CREATE POLICY "expenses insert own branch" ON public.expenses
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT auth.uid()) = created_by
    AND (
      (SELECT public.is_admin())
      OR (SELECT public.get_user_branch()) = 'الكل'
      OR branch = (SELECT public.get_user_branch())
    )
  );

-- 4) certificate_templates: لا يوجد عمود فرع (قوالب عامة للأكاديمية كلها).
--    القراءة لأي مستخدم فعّال، والتعديل/الحذف للأدمن فقط.
--    ⚠ تغيير سلوك: كان أي موظف يعدّل القوالب. لو تريد إبقاءه، احذف سياستي الكتابة
--    وأعد سياسة FOR ALL بشرط is_active_user().
DROP POLICY IF EXISTS "cert_templates_all_authenticated" ON public.certificate_templates;
CREATE POLICY "cert_templates_read_active" ON public.certificate_templates
  FOR SELECT TO authenticated
  USING ((SELECT public.is_active_user()));
CREATE POLICY "cert_templates_admin_write" ON public.certificate_templates
  FOR ALL TO authenticated
  USING ((SELECT public.is_admin()))
  WITH CHECK ((SELECT public.is_admin()));
