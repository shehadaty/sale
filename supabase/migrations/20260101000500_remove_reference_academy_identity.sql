-- ============================================================================
-- Migration 6: إزالة اسم الأكاديمية المرجعية من قاعدة البيانات.
--  1) نص الإنجاز التلقائي في award_attendance_milestone (كان يذكر اسم مركز).
--  2) عنوان الدوري الذهبي الافتراضي.
--  3) إعادة تسمية جدول مهام المساعد الذكي وقيوده وفهارسه (andalus_ai_tasks -> academy_ai_tasks).
-- هذه الـ Migration لقاعدة منشورة بالفعل. أما أي عميل جديد فيبدأ من baseline نظيف (انظر ملف إعداد العميل).
-- لم تُجرَّب على قاعدة فعلية بعد.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.award_attendance_milestone() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  present_count integer;
  milestone integer;
  achievement_title text;
BEGIN
  IF NEW.student_id IS NULL OR NEW.status <> 'حاضر' THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO present_count
  FROM public.attendance
  WHERE student_id = NEW.student_id AND status = 'حاضر';

  IF present_count NOT IN (1,5,10,20,30,50) THEN
    RETURN NEW;
  END IF;

  milestone := present_count;
  achievement_title := 'حضور والتزام — ' || milestone || ' محاضرة';

  IF NOT EXISTS (
    SELECT 1 FROM public.student_achievements
    WHERE student_id = NEW.student_id AND title = achievement_title
  ) THEN
    INSERT INTO public.student_achievements(
      student_id,achievement_type,title,description,achievement_date,created_by,points,activity_points
    ) VALUES (
      NEW.student_id,'attendance',achievement_title,
      'إنجاز تلقائي من النظام بناءً على تسجيل الحضور الفعلي.',
      CURRENT_DATE,'system',
      CASE WHEN milestone >= 10 THEN 5 ELSE 2 END,
      CASE WHEN milestone >= 10 THEN 8 ELSE 5 END
    );
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Attendance achievement trigger skipped for student %: %', NEW.student_id, SQLERRM;
  RETURN NEW;
END;
$$;

ALTER TABLE public.golden_league_settings ALTER COLUMN title SET DEFAULT 'الدوري الذهبي';
UPDATE public.golden_league_settings SET title = 'الدوري الذهبي' WHERE title LIKE '%الأندلس%' OR title LIKE '%الاندلس%';

ALTER TABLE public.andalus_ai_tasks RENAME TO academy_ai_tasks;
ALTER TABLE public.academy_ai_tasks RENAME CONSTRAINT andalus_ai_tasks_pkey TO academy_ai_tasks_pkey;
ALTER TABLE public.academy_ai_tasks RENAME CONSTRAINT andalus_ai_tasks_status_check TO academy_ai_tasks_status_check;
ALTER TABLE public.academy_ai_tasks RENAME CONSTRAINT andalus_ai_tasks_title_check TO academy_ai_tasks_title_check;
ALTER INDEX public.andalus_ai_tasks_due_idx RENAME TO academy_ai_tasks_due_idx;
ALTER INDEX public.andalus_ai_tasks_status_idx RENAME TO academy_ai_tasks_status_idx;
