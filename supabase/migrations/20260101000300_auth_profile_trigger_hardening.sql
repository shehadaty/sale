-- ============================================================================
-- Migration 4: تأمين إنشاء ملفات الموظفين (منع تصعيد الصلاحيات عبر التسجيل الذاتي).
--
-- المشكلة (من قراءة الكود، لم تُختبر على الأصل): دالة handle_new_user كانت تقرأ
-- الدور (role) والفرع (branch) من بيانات التسجيل التي يرسلها المتصفح نفسه
-- (raw_user_meta_data). ومفتاح المشروع العام ظاهر في الصفحة. فإذا كان التسجيل
-- الذاتي مفعّلًا، أي زائر يستطيع إرسال role='admin' ويصبح أدمن.
--
-- الإصلاح:
--  1) الدالة تتجاهل أي دور/فرع قادم من المتصفح: كل حساب جديد = موظف غير فعّال.
--  2) إنشاء الموظفين الفعلي يتم عبر Edge Function للأدمن فقط (admin-create-employee)
--     تضبط الدور والفرع والتفعيل بمفتاح الخدمة على السيرفر.
--  3) الـ Trigger على auth.users لم يكن ضمن dump الـ public، فيُنشأ هنا صراحة.
-- ويلزم أيضًا إغلاق «Allow new users to sign up» من إعدادات Auth (خطوة يدوية).
-- لم تُجرَّب على قاعدة فعلية بعد.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_username TEXT;
  v_full_name TEXT;
BEGIN
  v_username := COALESCE(NULLIF(NEW.raw_user_meta_data->>'username', ''), split_part(NEW.email, '@', 1));
  v_full_name := NEW.raw_user_meta_data->>'full_name';

  -- لا نقرأ role/branch من بيانات المستخدم أبدًا. الحساب الجديد موظف غير فعّال
  -- إلى أن يفعّله أدمن (عبر admin-create-employee أو يدويًا من SQL لأول أدمن).
  INSERT INTO public.user_profiles (id, username, full_name, role, branch, is_active)
  VALUES (NEW.id, v_username, v_full_name, 'employee', 'الكل', false)
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
