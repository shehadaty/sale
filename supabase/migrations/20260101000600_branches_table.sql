-- ============================================================================
-- Migration 7: جدول الفروع بدل القيود الثابتة (CHECK) التي كانت تحمل أسماء فروع الأكاديمية المرجعية.
--  * branches: مصدر أسماء الفروع الصالحة. الصف 'الكل' علامة خاصة (كل الفروع) تعتمد عليها الدوال والسياسات.
--  * استبدال user_profiles_branch_check و expenses_branch_check بمفتاح خارجي على branches(name)،
--    مع ON UPDATE CASCADE (تغيير اسم فرع يتبعه تلقائيًا في الموظفين والمصروفات).
--  * الأسماء الافتراضية: 'الفرع الرئيسي' و'الفرع الثاني'. تُغيَّر لكل عميل بـ UPDATE (انظر ملف إعداد العميل)
--    وبنفس القيم الموجودة في client.json، وقبل إدخال أي بيانات.
-- لم تُجرَّب على قاعدة فعلية بعد.
-- ============================================================================
CREATE TABLE public.branches (
  name        text PRIMARY KEY CHECK (length(btrim(name)) > 0),
  sort_order  integer NOT NULL DEFAULT 0,
  is_all      boolean NOT NULL DEFAULT false,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.branches FROM anon, authenticated;
GRANT SELECT ON public.branches TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.branches TO authenticated;

CREATE POLICY "branches_public_read" ON public.branches
  FOR SELECT TO anon, authenticated USING (is_active);
CREATE POLICY "branches_admin_write" ON public.branches
  FOR ALL TO authenticated
  USING ((SELECT public.is_admin())) WITH CHECK ((SELECT public.is_admin()));

INSERT INTO public.branches (name, sort_order, is_all) VALUES
  ('الكل', 0, true),
  ('الفرع الرئيسي', 1, false),
  ('الفرع الثاني', 2, false);

ALTER TABLE public.user_profiles DROP CONSTRAINT user_profiles_branch_check;
ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_branch_fkey FOREIGN KEY (branch) REFERENCES public.branches(name) ON UPDATE CASCADE;

ALTER TABLE public.expenses DROP CONSTRAINT expenses_branch_check;
ALTER TABLE public.expenses
  ADD CONSTRAINT expenses_branch_fkey FOREIGN KEY (branch) REFERENCES public.branches(name) ON UPDATE CASCADE,
  ADD CONSTRAINT expenses_branch_not_all CHECK (branch <> 'الكل');
