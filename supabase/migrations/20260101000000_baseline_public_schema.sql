-- ============================================================================
-- BASELINE: هيكل schema public كما هو في النظام المرجعي (هيكل فقط، بدون بيانات).
-- مصدره: supabase db dump --schema public من مشروع الأصل. لم يُعدَّل أي سطر منه.
-- التعديلات (الأمان، White Label) تأتي في Migrations لاحقة منفصلة، لا هنا.
-- الإضافة الوحيدة المطلوبة من المخطط: pgcrypto (دالة digest) في schema extensions.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;




SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."admin_add_weekly_quiz_question"("p_question" "text", "p_option_a" "text", "p_option_b" "text", "p_option_c" "text", "p_option_d" "text", "p_correct_option" "text", "p_category" "text" DEFAULT NULL::"text", "p_points" integer DEFAULT 10) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  new_id uuid;
  correct_key text := lower(btrim(coalesce(p_correct_option, '')));
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = auth.uid() AND up.is_active IS TRUE AND up.role = 'admin'
  ) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF btrim(coalesce(p_question,'')) = ''
     OR btrim(coalesce(p_option_a,'')) = ''
     OR btrim(coalesce(p_option_b,'')) = ''
     OR correct_key NOT IN ('a','b','c','d') THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_question');
  END IF;

  INSERT INTO public.quiz_bank_questions
    (question, option_a, option_b, option_c, option_d, correct_option, category, points)
  VALUES
    (btrim(p_question), btrim(p_option_a), btrim(p_option_b),
     COALESCE(NULLIF(btrim(p_option_c),''),'—'),
     COALESCE(NULLIF(btrim(p_option_d),''),'—'),
     correct_key, NULLIF(btrim(coalesce(p_category,'')),''), GREATEST(1,COALESCE(p_points,10)))
  RETURNING id INTO new_id;

  RETURN jsonb_build_object('ok',true,'id',new_id);
END;
$$;


ALTER FUNCTION "public"."admin_add_weekly_quiz_question"("p_question" "text", "p_option_a" "text", "p_option_b" "text", "p_option_c" "text", "p_option_d" "text", "p_correct_option" "text", "p_category" "text", "p_points" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_archive_study_summary_order"("p_order_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'غير مصرح';
  END IF;
  UPDATE public.study_summary_orders
     SET admin_deleted_at = COALESCE(admin_deleted_at, now()),
         updated_at = now()
   WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'order_not_found');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;


ALTER FUNCTION "public"."admin_archive_study_summary_order"("p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_get_weekly_quiz_bank"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  result_data jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = auth.uid() AND up.is_active IS TRUE AND up.role = 'admin'
  ) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', q.id,
    'question', q.question,
    'option_a', q.option_a,
    'option_b', q.option_b,
    'option_c', q.option_c,
    'option_d', q.option_d,
    'correct_option', q.correct_option,
    'category', q.category,
    'points', q.points,
    'active', q.active,
    'created_at', q.created_at
  ) ORDER BY q.created_at DESC), '[]'::jsonb)
  INTO result_data
  FROM public.quiz_bank_questions q;

  RETURN result_data;
END;
$$;


ALTER FUNCTION "public"."admin_get_weekly_quiz_bank"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."weekly_quiz_access_audit" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "student_name" "text" NOT NULL,
    "photo_path" "text" NOT NULL,
    "user_agent" "text",
    "browser_name" "text",
    "device_label" "text",
    "entered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "photo_consent_at" timestamp with time zone NOT NULL,
    "event_type" "text" DEFAULT 'entry'::"text" NOT NULL,
    "national_id_masked" "text",
    "phone_masked" "text",
    "outcome" "text",
    "failure_code" "text",
    "failure_reason" "text",
    "face_distance" numeric,
    "face_threshold" numeric,
    "reference_photo_url" "text",
    "verification_method" "text",
    "session_token" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."weekly_quiz_access_audit" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_identity_verification_report"("p_limit" integer DEFAULT 200, "p_outcome" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."weekly_quiz_access_audit"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_admin() then
    raise exception 'admin_required';
  end if;
  return query
    select a.*
    from public.weekly_quiz_access_audit a
    where p_outcome is null or a.outcome = p_outcome
    order by a.entered_at desc
    limit greatest(1,least(coalesce(p_limit,200),1000));
end;
$$;


ALTER FUNCTION "public"."admin_identity_verification_report"("p_limit" integer, "p_outcome" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_identity_verification_summary"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r jsonb;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  select jsonb_build_object(
    'total',count(*),
    'success',count(*) filter (where outcome='success'),
    'failure',count(*) filter (where outcome='failure'),
    'today',count(*) filter (where entered_at >= date_trunc('day',now())),
    'last_24h',count(*) filter (where entered_at >= now()-interval '24 hours'),
    'face_mismatch',count(*) filter (where failure_code='face_mismatch'),
    'no_face',count(*) filter (where failure_code='no_face'),
    'multiple_faces',count(*) filter (where failure_code='multiple_faces'),
    'identity_mismatch',count(*) filter (where failure_code in ('student_not_found','national_id_mismatch','phone_mismatch'))
  ) into r from public.weekly_quiz_access_audit;
  return r;
end;
$$;


ALTER FUNCTION "public"."admin_identity_verification_summary"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_reset_all_student_face_enrollments"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_updated integer := 0;
  v_sessions integer := 0;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.competition_face_enrollments
     set active = false, face_descriptor = null, updated_at = now()
   where active = true;
  get diagnostics v_updated = row_count;

  delete from public.competition_face_verified_sessions;
  get diagnostics v_sessions = row_count;

  return jsonb_build_object('ok', true, 'enrollments_reset', v_updated, 'sessions_removed', v_sessions);
end;
$$;


ALTER FUNCTION "public"."admin_reset_all_student_face_enrollments"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_reset_identity_registration"("p_student_ref" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  st public.students%rowtype;
  v_ref text := nullif(btrim(coalesce(p_student_ref,'')), '');
  v_deactivated integer := 0;
  v_sessions integer := 0;
  v_target text;
  v_enrollment text;
begin
  if not public.is_admin() then
    raise exception 'admin_required';
  end if;

  if v_ref is not null then
    select * into st from public.student_face_resolve(v_ref) limit 1;
    if st.id is null then
      return jsonb_build_object('ok',false,'reason','student_not_found','student_ref',v_ref);
    end if;
    v_target := st.id;
    v_enrollment := coalesce(nullif(st.enrollment_number,''),st.id);

    update public.competition_face_enrollments
       set active = false, updated_at = now()
     where student_id = v_target and active = true;
    get diagnostics v_deactivated = row_count;

    delete from public.competition_face_verified_sessions
     where student_id = v_target;
    get diagnostics v_sessions = row_count;

    insert into public.competition_security_logs
      (competition_type,competition_id,enrollment_number,student_id,event_type,outcome,reason,metadata)
    values
      ('identity','admin-reset',v_enrollment,v_target,'identity_reset','success','admin_reset_student',
       jsonb_build_object('deactivated_enrollments',v_deactivated,'revoked_sessions',v_sessions));

    return jsonb_build_object('ok',true,'scope','student','student_id',v_target,'enrollment_number',v_enrollment,
      'deactivated_enrollments',v_deactivated,'revoked_sessions',v_sessions,
      'message','تمت إعادة ضبط تسجيل الهوية لهذا الطالب، ويمكنه التسجيل من جديد.');
  else
    update public.competition_face_enrollments
       set active = false, updated_at = now()
     where active = true;
    get diagnostics v_deactivated = row_count;

    delete from public.competition_face_verified_sessions;
    get diagnostics v_sessions = row_count;

    insert into public.competition_security_logs
      (competition_type,competition_id,event_type,outcome,reason,metadata)
    values
      ('identity','admin-reset-all','identity_reset','success','admin_reset_all_students',
       jsonb_build_object('deactivated_enrollments',v_deactivated,'revoked_sessions',v_sessions));

    return jsonb_build_object('ok',true,'scope','all','deactivated_enrollments',v_deactivated,
      'revoked_sessions',v_sessions,
      'message','تمت إعادة ضبط تسجيلات الهوية لجميع الطلاب. يجب على كل طالب إعادة التسجيل.');
  end if;
end;
$$;


ALTER FUNCTION "public"."admin_reset_identity_registration"("p_student_ref" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_reset_student_device_binding"("p_student_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_student public.students%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_student
  from public.students
  where deleted_at is null
    and (btrim(id) = btrim(p_student_code)
      or btrim(coalesce(enrollment_number, '')) = btrim(p_student_code))
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'student_not_found');
  end if;

  delete from public.student_device_bindings where student_id = v_student.id;
  delete from public.competition_face_verified_sessions
    where student_id = v_student.id and competition_type = 'student_portal';

  insert into public.student_portal_access_logs
    (student_id, enrollment_number, student_name, phone, competition_type, event_type, outcome, reason, provider, metadata)
  values
    (v_student.id, coalesce(v_student.enrollment_number, v_student.id), v_student.name, v_student.phone,
     'student_portal', 'device_rebind_reset', 'success', 'admin_reset',
     'admin', jsonb_build_object('admin_user_id', auth.uid()));

  return jsonb_build_object('ok', true, 'student_id', v_student.id, 'student_name', v_student.name);
end;
$$;


ALTER FUNCTION "public"."admin_reset_student_device_binding"("p_student_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_reset_student_face_enrollment"("p_student_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_student_id text := btrim(coalesce(p_student_id, ''));
  v_updated integer := 0;
  v_sessions integer := 0;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_student_id = '' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_student_id');
  end if;
  if not exists (select 1 from public.students s where s.id = v_student_id and s.deleted_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'student_not_found');
  end if;

  update public.competition_face_enrollments
     set active = false, face_descriptor = null, updated_at = now()
   where student_id = v_student_id;
  get diagnostics v_updated = row_count;

  delete from public.competition_face_verified_sessions
   where student_id = v_student_id;
  get diagnostics v_sessions = row_count;

  return jsonb_build_object('ok', true, 'student_id', v_student_id,
                            'enrollments_reset', v_updated, 'sessions_removed', v_sessions);
end;
$$;


ALTER FUNCTION "public"."admin_reset_student_face_enrollment"("p_student_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_review_study_summary_order"("p_order_id" "uuid", "p_status" "text", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_order public.study_summary_orders%rowtype;
  v_days integer;
  v_ent_id uuid;
  v_package_id uuid;
  v_summary_id uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'غير مصرح';
  END IF;
  IF p_status NOT IN ('paid', 'pending_payment', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'حالة غير صالحة';
  END IF;

  SELECT * INTO v_order
  FROM public.study_summary_orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'طلب الشراء غير موجود';
  END IF;
  IF p_status = 'paid' AND nullif(btrim(coalesce(v_order.payment_reference,'')), '') IS NULL AND nullif(btrim(coalesce(v_order.payment_proof_path,'')), '') IS NULL THEN
    RAISE EXCEPTION 'لا يمكن تأكيد الدفع دون مرجع تحويل مسجل';
  END IF;

  UPDATE public.study_summary_orders
  SET status = p_status,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      reviewed_reason = NULLIF(trim(coalesce(p_reason,'')), ''),
      updated_at = now()
  WHERE id = p_order_id;

  IF p_status <> 'paid' THEN
    RETURN;
  END IF;

  SELECT pi.package_id INTO v_package_id
  FROM public.study_summary_package_items pi
  WHERE pi.summary_id = v_order.summary_id
  LIMIT 1;

  IF v_package_id IS NOT NULL THEN
    SELECT greatest(coalesce(p.validity_days, 2), 1)
    INTO v_days
    FROM public.study_summary_packages p
    WHERE p.id = v_package_id AND p.is_active = true;

    IF v_days IS NULL THEN
      RAISE EXCEPTION 'الباقة غير مفعلة أو غير موجودة';
    END IF;

    FOR v_summary_id IN
      SELECT pi.summary_id
      FROM public.study_summary_package_items pi
      WHERE pi.package_id = v_package_id
      ORDER BY pi.summary_id
    LOOP
      SELECT e.id INTO v_ent_id
      FROM public.study_summary_entitlements e
      WHERE e.student_id = v_order.student_id
        AND e.summary_id = v_summary_id
      ORDER BY (e.revoked_at IS NULL) DESC, e.created_at DESC
      LIMIT 1
      FOR UPDATE;

      IF v_ent_id IS NULL THEN
        INSERT INTO public.study_summary_entitlements
          (student_id, summary_id, order_id, starts_at, expires_at, created_at, revoked_at)
        VALUES
          (v_order.student_id, v_summary_id, v_order.id, now(),
           now() + make_interval(days => v_days), now(), NULL);
      ELSE
        UPDATE public.study_summary_entitlements
        SET order_id = v_order.id,
            starts_at = now(),
            expires_at = now() + make_interval(days => v_days),
            revoked_at = NULL
        WHERE id = v_ent_id;
      END IF;
      v_ent_id := NULL;
    END LOOP;

    IF EXISTS (
      SELECT 1
      FROM public.study_summary_package_items pi
      WHERE pi.package_id = v_package_id
        AND NOT EXISTS (
          SELECT 1 FROM public.study_summary_entitlements e
          WHERE e.student_id = v_order.student_id
            AND e.summary_id = pi.summary_id
            AND e.revoked_at IS NULL
            AND e.starts_at <= now()
            AND (e.expires_at IS NULL OR e.expires_at > now())
        )
    ) THEN
      RAISE EXCEPTION 'لم تكتمل إتاحة جميع أجزاء الباقة؛ أُلغيت العملية بالكامل';
    END IF;
  ELSE
    SELECT greatest(coalesce(sm.validity_days, 30), 1)
    INTO v_days
    FROM public.study_summaries sm
    WHERE sm.id = v_order.summary_id;

    SELECT e.id INTO v_ent_id
    FROM public.study_summary_entitlements e
    WHERE e.student_id = v_order.student_id
      AND e.summary_id = v_order.summary_id
    ORDER BY (e.revoked_at IS NULL) DESC, e.created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_ent_id IS NULL THEN
      INSERT INTO public.study_summary_entitlements
        (student_id, summary_id, order_id, starts_at, expires_at, created_at, revoked_at)
      VALUES
        (v_order.student_id, v_order.summary_id, v_order.id, now(),
         now() + make_interval(days => greatest(coalesce(v_days,30),1)), now(), NULL);
    ELSE
      UPDATE public.study_summary_entitlements
      SET order_id = v_order.id,
          starts_at = now(),
          expires_at = now() + make_interval(days => greatest(coalesce(v_days,30),1)),
          revoked_at = NULL
      WHERE id = v_ent_id;
    END IF;
  END IF;

  INSERT INTO public.study_summary_activity(student_id, summary_id, order_id, event_type, metadata)
  VALUES (
    v_order.student_id, v_order.summary_id, v_order.id, 'access_granted',
    jsonb_build_object('status', 'paid', 'order_code', v_order.order_code,
                       'package_id', v_package_id, 'granted_all_items', v_package_id IS NOT NULL)
  );
END;
$$;


ALTER FUNCTION "public"."admin_review_study_summary_order"("p_order_id" "uuid", "p_status" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_update_weekly_quiz_settings"("p_daily_time" "text", "p_questions_per_day" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_time time;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = auth.uid() AND up.is_active IS TRUE AND up.role = 'admin'
  ) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF p_questions_per_day IS NULL OR p_questions_per_day < 1 OR p_questions_per_day > 50 THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_question_count');
  END IF;

  BEGIN
    v_time := btrim(coalesce(p_daily_time,''))::time;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_time');
  END;

  UPDATE public.quiz_settings
  SET daily_time = v_time,
      questions_per_day = p_questions_per_day,
      updated_at = now()
  WHERE id = 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'reason','settings_row_missing');
  END IF;

  RETURN jsonb_build_object('ok',true);
END;
$$;


ALTER FUNCTION "public"."admin_update_weekly_quiz_settings"("p_daily_time" "text", "p_questions_per_day" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "jsonb" DEFAULT '[]'::"jsonb", "p_measure_column" "text" DEFAULT NULL::"text", "p_operation" "text" DEFAULT 'count'::"text", "p_filters" "jsonb" DEFAULT '[]'::"jsonb", "p_limit" integer DEFAULT 500) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
 groups text='';
 sql text;
 result jsonb;
 op text:=lower(coalesce(p_operation,'count'));
 lim integer:=greatest(1,least(coalesce(p_limit,500),500));
 f jsonb;
 col text;
 fo text;
 val jsonb;
 where_sql text='';
begin
 if not exists(
   select 1 from information_schema.tables
   where table_schema='public' and table_name=p_table and table_type='BASE TABLE'
 ) then raise exception 'Unknown table'; end if;

 if op not in('count','sum','avg','min','max') then
   raise exception 'Unsupported aggregate';
 end if;

 if jsonb_typeof(p_group_by)='array' and jsonb_array_length(p_group_by)>0 then
   select string_agg(format('%I',x),', ')
   into groups from jsonb_array_elements_text(p_group_by)x;
 end if;

 if jsonb_typeof(p_filters)='array' then
  for f in select value from jsonb_array_elements(p_filters) loop
   col:=f->>'column';
   fo:=lower(coalesce(f->>'operator','eq'));
   val:=f->'value';

   if not exists(
     select 1 from information_schema.columns
     where table_schema='public' and table_name=p_table and column_name=col
   ) then raise exception 'Unknown filter column'; end if;

   if fo='is_null' then
    where_sql:=where_sql||case when where_sql='' then ' where ' else ' and ' end||format('%I is null',col);
   elsif fo='not_null' then
    where_sql:=where_sql||case when where_sql='' then ' where ' else ' and ' end||format('%I is not null',col);
   elsif fo in('eq','neq','gt','gte','lt','lte','ilike') then
    where_sql:=where_sql||case when where_sql='' then ' where ' else ' and ' end||
      format('%I %s %L',col,
        case fo
          when 'eq' then '='
          when 'neq' then '<>'
          when 'gt' then '>'
          when 'gte' then '>='
          when 'lt' then '<'
          when 'lte' then '<='
          when 'ilte' then '<='
          when 'ilike' then 'ilike'
        end,
        trim(both '"' from val::text));
   end if;
  end loop;
 end if;

 if op='count' then
   sql:=format(
     'select coalesce(jsonb_agg(to_jsonb(q)),''[]''::jsonb)
      from (
       select %s count(*) as value
       from public.%I%s
       %s
       limit %s
      )q',
     case when groups<>'' then groups||', ' else '' end,
     p_table,
     where_sql,
     case when groups<>'' then 'group by '||groups||' order by value desc' else '' end,
     lim
   );
 else
   if p_measure_column is null or p_measure_column='' then
     raise exception 'Measure column required';
   end if;

   sql:=format(
     'select coalesce(jsonb_agg(to_jsonb(q)),''[]''::jsonb)
      from (
       select %s %s(%I) as value
       from public.%I%s
       %s
       limit %s
      )q',
     case when groups<>'' then groups||',' else '' end,
     op,
     p_measure_column,
     p_table,
     where_sql,
     case when groups<>'' then 'group by '||groups||' order by value desc' else '' end,
     lim
   );
 end if;

 execute sql into result;
 return coalesce(result,'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "jsonb", "p_measure_column" "text", "p_operation" "text", "p_filters" "jsonb", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "text"[] DEFAULT NULL::"text"[], "p_count_column" "text" DEFAULT NULL::"text", "p_sum_column" "text" DEFAULT NULL::"text", "p_avg_column" "text" DEFAULT NULL::"text", "p_min_column" "text" DEFAULT NULL::"text", "p_max_column" "text" DEFAULT NULL::"text", "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  allowed boolean;
  sql text;
  select_sql text := '';
  group_sql text := '';
  where_sql text := '';
  key text;
  value jsonb;
  v text;
  result jsonb;
  i integer;
begin
  if p_limit is null or p_limit < 1 then p_limit := 100; end if;
  if p_limit > 500 then p_limit := 500; end if;

  select exists(
    select 1 from information_schema.tables
    where table_schema='public' and table_name=p_table
  ) into allowed;

  if not allowed then raise exception 'table_not_found:%', p_table; end if;

  if p_group_by is not null and array_length(p_group_by,1) is not null then
    for i in 1..array_length(p_group_by,1) loop
      if exists(
        select 1 from information_schema.columns
        where table_schema='public'
          and table_name=p_table
          and column_name=p_group_by[i]
      ) then
        select_sql := select_sql ||
          case when select_sql='' then '' else ', ' end ||
          format('%I', p_group_by[i]);
        group_sql := group_sql ||
          case when group_sql='' then '' else ', ' end ||
          format('%I', p_group_by[i]);
      end if;
    end loop;
  end if;

  if p_count_column is not null and exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name=p_count_column
  ) then
    select_sql := select_sql ||
      case when select_sql='' then '' else ', ' end ||
      format('count(%I) as count', p_count_column);
  else
    select_sql := select_sql ||
      case when select_sql='' then '' else ', ' end ||
      'count(*) as count';
  end if;

  if p_sum_column is not null and exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name=p_sum_column
  ) then
    select_sql := select_sql ||
      ', sum(' || format('%I',p_sum_column) || ') as sum';
  end if;

  if p_avg_column is not null and exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name=p_avg_column
  ) then
    select_sql := select_sql ||
      ', avg(' || format('%I',p_avg_column) || ') as avg';
  end if;

  if p_min_column is not null and exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name=p_min_column
  ) then
    select_sql := select_sql ||
      ', min(' || format('%I',p_min_column) || ') as min';
  end if;

  if p_max_column is not null and exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name=p_max_column
  ) then
    select_sql := select_sql ||
      ', max(' || format('%I',p_max_column) || ') as max';
  end if;

  if jsonb_typeof(p_filters)='object' then
    for key,value in select * from jsonb_each(p_filters)
    loop
      if not exists(
        select 1 from information_schema.columns
        where table_schema='public'
          and table_name=p_table
          and column_name=key
      ) then continue; end if;

      v := trim(both '"' from value::text);

      if value='null'::jsonb then
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I is null',key);
      elsif jsonb_typeof(value)='number' then
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I = %L',key,v);
      elsif jsonb_typeof(value)='boolean' then
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I = %L::boolean',key,v);
      else
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I::text ilike %L',key,'%'||v||'%');
      end if;
    end loop;
  end if;

  sql := format(
    'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (select %s from public.%I%s%s limit %s) x',
    select_sql,
    p_table,
    where_sql,
    case when group_sql='' then '' else ' group by '||group_sql end,
    p_limit
  );

  execute sql into result;
  return coalesce(result,'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "text"[], "p_count_column" "text", "p_sum_column" "text", "p_avg_column" "text", "p_min_column" "text", "p_max_column" "text", "p_filters" "jsonb", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[] DEFAULT NULL::"text"[], "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  sql text;
  cols text;
  result jsonb;
  safe_limit integer;
  filter_key text;
  filter_value jsonb;
  filter_text text;
  where_sql text := '';
begin

  if p_table is null
     or p_table !~ '^[A-Za-z_][A-Za-z0-9_]*$'
  then
    raise exception 'Invalid table name';
  end if;

  if not exists (
    select 1
    from information_schema.tables
    where table_schema = 'public'
      and table_name = p_table
      and table_type = 'BASE TABLE'
  ) then
    raise exception 'Table not found: %', p_table;
  end if;

  safe_limit := greatest(
    1,
    least(coalesce(p_limit, 100), 500)
  );

  if p_columns is null
     or array_length(p_columns, 1) is null
  then

    select string_agg(
      format('%I', column_name),
      ', ' order by ordinal_position
    )
    into cols
    from information_schema.columns
    where table_schema = 'public'
      and table_name = p_table;

  else

    if exists (
      select 1
      from unnest(p_columns) x
      where not exists (
        select 1
        from information_schema.columns c
        where c.table_schema = 'public'
          and c.table_name = p_table
          and c.column_name = x
      )
    ) then
      raise exception 'One or more requested columns do not exist';
    end if;

    select string_agg(
      format('%I', x),
      ', '
    )
    into cols
    from unnest(p_columns) x;

  end if;

  /*
    الفلاتر:
    {"name":"مكافحة العدوى"}
    {"status":"present"}
    {"id":5001}
    {"active":true}
  */

  if p_filters is not null
     and jsonb_typeof(p_filters) = 'object'
  then

    for filter_key, filter_value in
      select key, value
      from jsonb_each(p_filters)
    loop

      if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = p_table
          and column_name = filter_key
      ) then
        continue;
      end if;

      filter_text := trim(
        both '"' from filter_value::text
      );

      if jsonb_typeof(filter_value) = 'null' then

        where_sql :=
          where_sql ||
          case
            when where_sql = '' then ' where '
            else ' and '
          end ||
          format('%I is null', filter_key);

      elsif jsonb_typeof(filter_value) = 'string' then

        where_sql :=
          where_sql ||
          case
            when where_sql = '' then ' where '
            else ' and '
          end ||
          format(
            '%I::text ilike %L',
            filter_key,
            '%' || filter_text || '%'
          );

      elsif jsonb_typeof(filter_value) = 'number' then

        where_sql :=
          where_sql ||
          case
            when where_sql = '' then ' where '
            else ' and '
          end ||
          format(
            '%I::text = %L',
            filter_key,
            filter_text
          );

      elsif jsonb_typeof(filter_value) = 'boolean' then

        where_sql :=
          where_sql ||
          case
            when where_sql = '' then ' where '
            else ' and '
          end ||
          format(
            '%I::text = %L',
            filter_key,
            filter_text
          );

      end if;

    end loop;

  end if;

  sql := format(
    'select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb)
     from (
       select %s
       from public.%I
       %s
       limit %s
     ) q',
    cols,
    p_table,
    where_sql,
    safe_limit
  );

  execute sql into result;

  return coalesce(result, '[]'::jsonb);

end;
$_$;


ALTER FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[], "p_filters" "jsonb", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[] DEFAULT NULL::"text"[], "p_filters" "jsonb" DEFAULT '{}'::"jsonb", "p_order_by" "text" DEFAULT NULL::"text", "p_order_desc" boolean DEFAULT false, "p_limit" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  allowed boolean;
  cols text;
  sql text;
  where_sql text := '';
  order_sql text := '';
  key text;
  value jsonb;
  v text;
  result jsonb;
begin
  if p_limit is null or p_limit < 1 then p_limit := 100; end if;
  if p_limit > 500 then p_limit := 500; end if;

  select exists(
    select 1
    from information_schema.tables
    where table_schema = 'public'
      and table_name = p_table
  ) into allowed;

  if not allowed then
    raise exception 'table_not_found:%', p_table;
  end if;

  if p_columns is null or array_length(p_columns,1) is null then
    select string_agg(format('%I', column_name), ', ' order by ordinal_position)
    into cols
    from information_schema.columns
    where table_schema = 'public'
      and table_name = p_table;
  else
    select string_agg(format('%I', x), ', ')
    into cols
    from unnest(p_columns) x
    where exists(
      select 1
      from information_schema.columns
      where table_schema='public'
        and table_name=p_table
        and column_name=x
    );

    if cols is null then
      raise exception 'no_valid_columns';
    end if;
  end if;

  if jsonb_typeof(p_filters) = 'object' then
    for key, value in select * from jsonb_each(p_filters)
    loop
      if not exists(
        select 1 from information_schema.columns
        where table_schema='public'
          and table_name=p_table
          and column_name=key
      ) then
        continue;
      end if;

      v := trim(both '"' from value::text);

      if value = 'null'::jsonb then
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I is null', key);

      elsif jsonb_typeof(value) = 'array' then
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I = any (select jsonb_array_elements_text(%L::jsonb))', key, value::text);

      elsif jsonb_typeof(value) = 'boolean' then
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I = %L::boolean', key, v);

      elsif jsonb_typeof(value) = 'number' then
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I = %L', key, v);

      else
        where_sql := where_sql || case when where_sql='' then ' where ' else ' and ' end
          || format('%I::text ilike %L', key, '%' || v || '%');
      end if;
    end loop;
  end if;

  if p_order_by is not null
     and exists(
       select 1 from information_schema.columns
       where table_schema='public'
         and table_name=p_table
         and column_name=p_order_by
     ) then
    order_sql := format(
      ' order by %I %s nulls last',
      p_order_by,
      case when p_order_desc then 'desc' else 'asc' end
    );
  end if;

  sql := format(
    'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (select %s from public.%I%s%s limit %s) x',
    cols,
    p_table,
    where_sql,
    order_sql,
    p_limit
  );

  execute sql into result;
  return coalesce(result, '[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[], "p_filters" "jsonb", "p_order_by" "text", "p_order_desc" boolean, "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "jsonb" DEFAULT '[]'::"jsonb", "p_filters" "jsonb" DEFAULT '[]'::"jsonb", "p_order_by" "text" DEFAULT NULL::"text", "p_order_desc" boolean DEFAULT false, "p_limit" integer DEFAULT 500) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
 cols text;
 sql text;
 f jsonb;
 col text;
 op text;
 val jsonb;
 where_sql text='';
 order_sql text='';
 result jsonb;
 lim integer:=greatest(1,least(coalesce(p_limit,500),500));
begin
 if not exists(
   select 1 from information_schema.tables
   where table_schema='public' and table_name=p_table and table_type='BASE TABLE'
 ) then raise exception 'Unknown table'; end if;

 if jsonb_typeof(p_columns)='array' and jsonb_array_length(p_columns)>0 then
   select string_agg(format('%I',x),', ')
   into cols from jsonb_array_elements_text(p_columns)x;
 else
   select string_agg(format('%I',column_name),', ' order by ordinal_position)
   into cols
   from information_schema.columns
   where table_schema='public' and table_name=p_table;
 end if;

 if exists(
   select 1 from jsonb_array_elements_text(
     case when jsonb_typeof(p_columns)='array' then p_columns else '[]'::jsonb end
   )x
   where not exists(
     select 1 from information_schema.columns c
     where c.table_schema='public'
       and c.table_name=p_table
       and c.column_name=x
   )
 ) then raise exception 'One or more requested columns do not exist'; end if;

 if jsonb_typeof(p_filters)='array' then
  for f in select value from jsonb_array_elements(p_filters) loop
   col:=f->>'column';
   op:=lower(coalesce(f->>'operator','eq'));
   val:=f->'value';

   if not exists(
     select 1 from information_schema.columns c
     where c.table_schema='public' and c.table_name=p_table and c.column_name=col
   ) then raise exception 'Unknown filter column'; end if;

   if op='is_null' then
    where_sql:=where_sql||case when where_sql='' then ' where ' else ' and ' end||format('%I is null',col);
   elsif op='not_null' then
    where_sql:=where_sql||case when where_sql='' then ' where ' else ' and ' end||format('%I is not null',col);
   elsif op in('eq','neq','gt','gte','lt','lte','ilike') then
    where_sql:=where_sql||case when where_sql='' then ' where ' else ' and ' end||
      format('%I %s %L',col,
        case op
          when 'eq' then '='
          when 'neq' then '<>'
          when 'gt' then '>'
          when 'gte' then '>='
          when 'lt' then '<'
          when 'lte' then '<='
          when 'ilike' then 'ilike'
        end,
        trim(both '"' from val::text));
   elsif op='in' and jsonb_typeof(val)='array' then
    where_sql:=where_sql||case when where_sql='' then ' where ' else ' and ' end||
      format('%I in (%s)',col,
        (select string_agg(format('%L',trim(both '"' from z::text)),',')
         from jsonb_array_elements(val)z));
   else raise exception 'Unsupported filter operator'; end if;
  end loop;
 end if;

 if p_order_by is not null and p_order_by<>'' then
  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name=p_order_by
  ) then raise exception 'Unknown order column'; end if;
  order_sql:=format(' order by %I %s',p_order_by,
    case when p_order_desc then 'desc' else 'asc' end);
 end if;

 sql:=format(
   'select coalesce(jsonb_agg(to_jsonb(q)),''[]''::jsonb)
    from (select %s from public.%I%s%s limit %s)q',
   cols,p_table,where_sql,order_sql,lim
 );

 execute sql into result;
 return coalesce(result,'[]'::jsonb);
end;
$$;


ALTER FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "jsonb", "p_filters" "jsonb", "p_order_by" "text", "p_order_desc" boolean, "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ai_schema"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object(
   'table',c.table_name,
   'column',c.column_name,
   'type',c.data_type,
   'nullable',c.is_nullable='YES'
 ) order by c.table_name,c.ordinal_position),'[]'::jsonb)
 into r
 from information_schema.columns c
 where c.table_schema='public'
   and c.table_name not like 'pg_%'
   and c.table_name not like 'supabase_%'
   and c.table_name not in ('ai_conversations');
 return r;
end;
$$;


ALTER FUNCTION "public"."ai_schema"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_log_event"("p_action_type" "text", "p_module" "text" DEFAULT 'النظام'::"text", "p_title" "text" DEFAULT NULL::"text", "p_details" "jsonb" DEFAULT '{}'::"jsonb") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ declare v_id bigint; begin if auth.uid() is null then raise exception 'authentication_required'; end if; insert into public.employee_activity_log(actor_user_id,action_type,module,title,details) values(auth.uid(),left(coalesce(p_action_type,'activity'),80),left(coalesce(p_module,'النظام'),120),left(p_title,300),public.audit_log_sanitize(coalesce(p_details,'{}'::jsonb))) returning id into v_id; return v_id; end; $$;


ALTER FUNCTION "public"."audit_log_event"("p_action_type" "text", "p_module" "text", "p_title" "text", "p_details" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_log_get_user"("p_user_id" "uuid", "p_page" integer DEFAULT 1, "p_page_size" integer DEFAULT 100) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
 v_offset integer:=greatest(coalesce(p_page,1)-1,0)*least(greatest(coalesce(p_page_size,100),1),200);
 v_size integer:=least(greatest(coalesce(p_page_size,100),1),200);
 v_total bigint; v_login bigint; v_change bigint; v_last timestamptz; v_events jsonb;
begin
 if not public.is_admin() then raise exception 'admin_required'; end if;
 if not exists(select 1 from public.user_profiles where id=p_user_id) then raise exception 'user_not_found'; end if;
 select count(*) into v_total from public.employee_activity_log where actor_user_id=p_user_id;
 select count(*) into v_login from public.employee_activity_log where actor_user_id=p_user_id and action_type in ('login','login_session');
 select count(*) into v_change from public.employee_activity_log where actor_user_id=p_user_id and action_type in ('insert','update','delete','create','edit','delete_record');
 select max(created_at) into v_last from public.employee_activity_log where actor_user_id=p_user_id;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_events
 from (
  select e.id,e.created_at,e.action_type,
   case e.action_type when 'login' then 'تسجيل دخول' when 'logout' then 'تسجيل خروج'
   when 'login_session' then 'بدء جلسة' when 'page_view' then 'فتح شاشة'
   when 'click' then 'ضغط / تنفيذ إجراء' when 'insert' then 'إضافة سجل'
   when 'update' then 'تعديل سجل' when 'delete' then 'حذف سجل'
   when 'create' then 'إنشاء' when 'edit' then 'تعديل'
   when 'delete_record' then 'حذف' when 'download' then 'تحميل'
   when 'export' then 'تصدير' else e.action_type end action_label,
   e.module,e.entity_table,e.entity_id,e.title,
   case
    when e.entity_table='payments' then coalesce(e.details,'{}'::jsonb) || jsonb_build_object(
     'student_name',coalesce(e.details->>'student_name',s.name),'label',coalesce(e.details->>'label',p.label),
     'amount',coalesce(e.details->>'amount',p.amount::text),'paid_date',coalesce(e.details->>'paid_date',p.paid_date),
     'payment_type',coalesce(e.details->>'payment_type',p.payment_type),
     'payment_status',case when p.paid then 'مدفوع' else 'غير مدفوع' end)
    when e.entity_table='daily_revenue' then coalesce(e.details,'{}'::jsonb) || jsonb_build_object(
     'student_name',coalesce(e.details->>'student_name',dr.student_name),'amount',coalesce(e.details->>'amount',dr.amount::text),
     'revenue_date',coalesce(e.details->>'revenue_date',dr.revenue_date::text),'description',coalesce(e.details->>'description',dr.details),
     'branch',coalesce(e.details->>'branch',dr.branch))
    when e.entity_table='expenses' then coalesce(e.details,'{}'::jsonb) || jsonb_build_object(
     'item',coalesce(e.details->>'item',ex.item),'amount',coalesce(e.details->>'amount',ex.amount::text),
     'expense_date',coalesce(e.details->>'expense_date',ex.expense_date::text),'notes',coalesce(e.details->>'notes',ex.notes),
     'branch',coalesce(e.details->>'branch',ex.branch))
    when e.entity_table='cash_register_logs' then coalesce(e.details,'{}'::jsonb) || jsonb_build_object(
     'branch',coalesce(e.details->>'branch',cr.branch),'log_date',coalesce(e.details->>'log_date',cr.log_date::text),
     'opening_balance',coalesce(e.details->>'opening_balance',cr.opening_balance::text),
     'expected_cash',coalesce(e.details->>'expected_cash',cr.expected_cash::text),
     'actual_cash',coalesce(e.details->>'actual_cash',cr.actual_cash::text),'notes',coalesce(e.details->>'notes',cr.notes))
    else e.details end as details,
   case when e.entity_table='payments' then coalesce(e.old_data,'{}'::jsonb) || jsonb_build_object('student_name',s.name,'label',p.label,'amount',p.amount,'paid_date',p.paid_date,'payment_type',p.payment_type) else e.old_data end as old_data,
   case when e.entity_table='payments' then coalesce(e.new_data,'{}'::jsonb) || jsonb_build_object('student_name',s.name,'label',p.label,'amount',p.amount,'paid_date',p.paid_date,'payment_type',p.payment_type) else e.new_data end as new_data
  from public.employee_activity_log e
  left join public.payments p on e.entity_table='payments' and p.id::text=e.entity_id
  left join public.students s on s.id=p.student_id
  left join public.daily_revenue dr on e.entity_table='daily_revenue' and dr.id::text=e.entity_id
  left join public.expenses ex on e.entity_table='expenses' and ex.id::text=e.entity_id
  left join public.cash_register_logs cr on e.entity_table='cash_register_logs' and cr.id::text=e.entity_id
  where e.actor_user_id=p_user_id
  order by e.created_at desc offset v_offset limit v_size
 ) x;
 v_events := (select coalesce(jsonb_agg(z order by (z->>'created_at')::timestamptz desc),'[]'::jsonb)
  from (
   select jsonb_build_object('id',-1,'created_at',u.created_at,'action_type','account_created',
    'action_label','إنشاء حساب الموظف','module','المستخدمون والصلاحيات','entity_table','user_profiles',
    'entity_id',u.id::text,'title','تم إنشاء حساب الموظف',
    'details',jsonb_build_object('username',u.username,'role',u.role,'branch',u.branch)) z
   from public.user_profiles u where u.id=p_user_id
   union all select value from jsonb_array_elements(v_events)
  ) z);
 return jsonb_build_object('total_count',v_total+1,'login_count',v_login,'change_count',v_change,
  'last_activity',coalesce(v_last,(select created_at from public.user_profiles where id=p_user_id)),'events',v_events);
end; $$;


ALTER FUNCTION "public"."audit_log_get_user"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "full_name" "text",
    "role" "text" DEFAULT 'employee'::"text" NOT NULL,
    "branch" "text" DEFAULT 'الكل'::"text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "phone" "text",
    "address" "text",
    "qualification" "text",
    "hiring_date" "date",
    "salary" numeric(10,2),
    "allowed_pages" "jsonb",
    "can_delete" boolean DEFAULT true,
    "commission_amount" numeric DEFAULT 0,
    CONSTRAINT "user_profiles_branch_check" CHECK (("branch" = ANY (ARRAY['الكل'::"text", 'كفر الدوار'::"text", 'فيكتوريا'::"text"]))),
    CONSTRAINT "user_profiles_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'employee'::"text"])))
);


ALTER TABLE "public"."user_profiles" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_log_get_users"("p_search" "text" DEFAULT NULL::"text", "p_role" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."user_profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ begin if not public.is_admin() then raise exception 'admin_required'; end if; return query select u.* from public.user_profiles u where (nullif(trim(p_role),'') is null or u.role=trim(p_role)) and (nullif(trim(p_search),'') is null or u.full_name ilike '%'||trim(p_search)||'%' or u.username ilike '%'||trim(p_search)||'%') order by coalesce(u.full_name,u.username),u.created_at; end; $$;


ALTER FUNCTION "public"."audit_log_get_users"("p_search" "text", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_log_sanitize"("p" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    AS $$ select coalesce(p,'{}'::jsonb) - 'password' - 'password_hash' - 'access_token' - 'refresh_token' - 'token' - 'face_token' - 'secret' - 'api_key' - 'service_role_key'; $$;


ALTER FUNCTION "public"."audit_log_sanitize"("p" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_activate_daily_quiz"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  egypt_now timestamp;
  egypt_today date;
BEGIN
  egypt_now := now() AT TIME ZONE 'Africa/Cairo';
  egypt_today := egypt_now::date;

  -- لا تفعل شيئًا قبل 8:30 مساءً بتوقيت مصر
  IF egypt_now::time < TIME '20:30:00' THEN
    RETURN;
  END IF;

  -- لو سؤال اليوم موجود، لا تعمل شيئًا
  IF EXISTS (
    SELECT 1
    FROM public.daily_quiz_schedule
    WHERE quiz_date = egypt_today
  ) THEN
    RETURN;
  END IF;

  -- التفعيل الفعلي
  PERFORM public.activate_daily_quiz();
END;
$$;


ALTER FUNCTION "public"."auto_activate_daily_quiz"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_hide_expelled_student"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.type = 'فصل' then
    update public.students
       set deleted_at = coalesce(deleted_at, now()),
           deleted_by = coalesce(deleted_by, new.created_by)
     where id = new.student_id
       and deleted_at is null;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."auto_hide_expelled_student"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."award_attendance_milestone"() RETURNS "trigger"
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
      'إنجاز تلقائي من نظام مركز الأندلس بناءً على تسجيل الحضور الفعلي.',
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


ALTER FUNCTION "public"."award_attendance_milestone"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_access_student"("p_student_id" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT public.is_admin() OR public.student_in_user_branch(public.get_student_branch(p_student_id));
$$;


ALTER FUNCTION "public"."can_access_student"("p_student_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_upload_study_summary_payment_proof"("p_session_token" "text", "p_order_id" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
 SELECT EXISTS (
   SELECT 1
   FROM public.competition_face_verified_sessions s
   JOIN public.study_summary_orders o ON o.id::text=p_order_id AND o.student_id=s.student_id
   JOIN public.students st ON st.id=s.student_id
   WHERE s.token::text=p_session_token
     AND s.competition_type='student_portal'
     AND s.expires_at>now()
     AND st.deleted_at IS NULL
     AND coalesce(st.student_status,'active')='active'
     AND o.status='pending_payment'
     AND (o.expires_at IS NULL OR o.expires_at>now())
 );
$$;


ALTER FUNCTION "public"."can_upload_study_summary_payment_proof"("p_session_token" "text", "p_order_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_upload_weekly_quiz_audit"("p_name" "text") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'storage'
    AS $_$
  SELECT coalesce(
    p_name ~ '^audit/[A-Za-z0-9_-]+/[0-9a-fA-F-]{36}/[^/]+$'
    AND EXISTS (
      SELECT 1
      FROM public.competition_face_verified_sessions v
      WHERE v.student_id = split_part(p_name, '/', 2)
        AND v.token::text = split_part(p_name, '/', 3)
        AND v.competition_type = 'weekly_quiz'
        AND v.expires_at > now()
    ),
    false
  );
$_$;


ALTER FUNCTION "public"."can_upload_weekly_quiz_audit"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_pending_summary_orders_after_access"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_package_id uuid;
  v_representative_id uuid;
  v_all_owned boolean;
BEGIN
  IF NEW.revoked_at IS NOT NULL
     OR NEW.starts_at > now()
     OR (NEW.expires_at IS NOT NULL AND NEW.expires_at <= now()) THEN
    RETURN NEW;
  END IF;

  SELECT pi.package_id INTO v_package_id
  FROM public.study_summary_package_items pi
  WHERE pi.summary_id = NEW.summary_id
  LIMIT 1;

  IF v_package_id IS NULL THEN
    UPDATE public.study_summary_orders o
    SET status='cancelled',
        reviewed_reason='إلغاء تلقائي: توجد إتاحة فعالة للملخص بالفعل',
        reviewed_at=now(),
        updated_at=now()
    WHERE o.student_id=NEW.student_id
      AND o.summary_id=NEW.summary_id
      AND o.status='pending_payment'
      AND o.admin_deleted_at IS NULL;
    RETURN NEW;
  END IF;

  SELECT pi.summary_id INTO v_representative_id
  FROM public.study_summary_package_items pi
  WHERE pi.package_id=v_package_id
  ORDER BY pi.created_at,pi.summary_id
  LIMIT 1;

  SELECT bool_and(EXISTS (
    SELECT 1 FROM public.study_summary_entitlements e
    WHERE e.student_id=NEW.student_id
      AND e.summary_id=pi.summary_id
      AND e.revoked_at IS NULL
      AND e.starts_at<=now()
      AND (e.expires_at IS NULL OR e.expires_at>now())
  ))
  INTO v_all_owned
  FROM public.study_summary_package_items pi
  WHERE pi.package_id=v_package_id;

  IF coalesce(v_all_owned,false) THEN
    UPDATE public.study_summary_orders o
    SET status='cancelled',
        reviewed_reason='إلغاء تلقائي: توجد إتاحة فعالة لجميع أجزاء الباقة بالفعل',
        reviewed_at=now(),
        updated_at=now()
    WHERE o.student_id=NEW.student_id
      AND o.summary_id=v_representative_id
      AND o.status='pending_payment'
      AND o.admin_deleted_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."cancel_pending_summary_orders_after_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."competition_identity_admin_report"("p_limit" integer DEFAULT 200) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
  v_result jsonb;
begin
  if auth.uid() is null or not exists (
    select 1 from public.user_profiles p
    where p.id = auth.uid() and p.role = 'admin' and p.is_active = true
  ) then
    raise exception 'admin_only';
  end if;

  select jsonb_build_object(
    'security_logs', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select id, competition_type, competition_id, enrollment_number, student_id,
               event_type, outcome, reason, device_label, user_agent, metadata, created_at
        from public.competition_security_logs
        order by created_at desc limit v_limit
      ) x
    ), '[]'::jsonb),
    'verification_attempts', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.entered_at desc)
      from (
        select id, student_id, student_name, photo_path, user_agent, browser_name, device_label,
               entered_at, photo_consent_at, event_type, national_id_masked, phone_masked,
               outcome, failure_code, failure_reason, face_distance, face_threshold,
               reference_photo_url, verification_method, metadata
        from public.weekly_quiz_access_audit
        order by entered_at desc limit v_limit
      ) x
    ), '[]'::jsonb),
    'face_enrollments', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select id, student_id, enrollment_number, provider, consent_at, consent_version,
               active, created_at, updated_at, model_version
        from public.competition_face_enrollments
        order by created_at desc limit v_limit
      ) x
    ), '[]'::jsonb),
    'verified_sessions', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select student_id, competition_type, competition_id, created_at, expires_at,
               (expires_at > now()) as session_active
        from public.competition_face_verified_sessions
        order by created_at desc limit v_limit
      ) x
    ), '[]'::jsonb),
    'portal_access_logs', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select id, student_id, enrollment_number, student_name, competition_type,
               competition_id, event_type, outcome, reason, distance, threshold,
               model_version, provider, metadata, created_at
        from public.student_portal_access_logs
        order by created_at desc limit v_limit
      ) x
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."competition_identity_admin_report"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."competition_security_admin_logs"("p_limit" integer DEFAULT 200) RETURNS TABLE("id" bigint, "competition_type" "text", "competition_id" "text", "enrollment_number" "text", "student_id" "text", "event_type" "text", "outcome" "text", "reason" "text", "ip_address" "inet", "user_agent" "text", "device_label" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  caller uuid := auth.uid();
begin
  if caller is null or not exists (
    select 1 from public.user_profiles p
    where p.id = caller and p.role = 'admin' and coalesce(p.is_active,true) = true
  ) then
    raise exception 'admin_only';
  end if;

  return query
  select c.id, c.competition_type, c.competition_id, c.enrollment_number,
         c.student_id, c.event_type, c.outcome, c.reason, c.ip_address,
         c.user_agent, c.device_label, c.created_at
  from public.competition_security_logs c
  order by c.created_at desc
  limit greatest(1, least(coalesce(p_limit,200),500));
end;
$$;


ALTER FUNCTION "public"."competition_security_admin_logs"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dismiss_student"("p_student_id" "text", "p_reason" "text" DEFAULT NULL::"text", "p_decision_number" "text" DEFAULT NULL::"text", "p_action_date" "date" DEFAULT CURRENT_DATE, "p_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user uuid := auth.uid();
  v_created_by uuid;
  v_student public.students%rowtype;
begin
  if v_user is null or not exists(
    select 1 from public.user_profiles
    where id=v_user and role='admin' and coalesce(is_active,true)
  ) then raise exception 'admin_only'; end if;

  select * into v_student from public.students where id=p_student_id for update;
  if not found then raise exception 'student_not_found'; end if;
  if coalesce(v_student.student_status,'active') in ('dismissed','final_dismissed') then
    raise exception 'student_already_dismissed';
  end if;

  v_created_by := case when exists(select 1 from public.users where id=v_user) then v_user else null end;

  insert into public.student_disciplinary_actions
    (student_id,action_type,action_date,decision_number,reason,notes,created_by)
  values
    (p_student_id,'dismissal',p_action_date,p_decision_number,p_reason,p_notes,v_user);

  update public.students
  set student_status='dismissed',
      dismissed_at=now(),
      dismissed_by=v_user,
      deleted_at=null,
      deleted_by=null
  where id=p_student_id;

  if v_created_by is not null then
    insert into public.procedures(student_id,type,reference_number,date,details,result,created_by,created_at)
    values(p_student_id,'قرار فصل',p_decision_number,to_char(p_action_date,'YYYY-MM-DD'),p_reason,p_notes,v_created_by,now());
  else
    insert into public.procedures(student_id,type,reference_number,date,details,result,created_at)
    values(p_student_id,'قرار فصل',p_decision_number,to_char(p_action_date,'YYYY-MM-DD'),p_reason,p_notes,now());
  end if;

  return jsonb_build_object('success',true,'student_id',p_student_id,'status','dismissed');
end $$;


ALTER FUNCTION "public"."dismiss_student"("p_student_id" "text", "p_reason" "text", "p_decision_number" "text", "p_action_date" "date", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."employee_activity_audit_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ declare v_actor uuid:=auth.uid(); v_old jsonb; v_new jsonb; v_entity text; begin if tg_table_name='employee_activity_log' then return coalesce(new,old); end if; v_old:=case when tg_op in ('UPDATE','DELETE') then public.audit_log_sanitize(to_jsonb(old)) end; v_new:=case when tg_op in ('INSERT','UPDATE') then public.audit_log_sanitize(to_jsonb(new)) end; v_entity:=coalesce((case when tg_op='DELETE' then v_old else v_new end)->>'id',(case when tg_op='DELETE' then v_old else v_new end)->>'uuid'); insert into public.employee_activity_log(actor_user_id,action_type,module,entity_table,entity_id,title,details,old_data,new_data) values(v_actor,lower(tg_op),replace(tg_table_name,'_',' '),tg_table_name,v_entity,case tg_op when 'INSERT' then 'إضافة سجل في '||tg_table_name when 'UPDATE' then 'تعديل سجل في '||tg_table_name when 'DELETE' then 'حذف سجل من '||tg_table_name end,jsonb_build_object('operation',tg_op,'source','database_trigger'),v_old,v_new); return coalesce(new,old); exception when others then return coalesce(new,old); end; $$;


ALTER FUNCTION "public"."employee_activity_audit_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_weekly_quiz_session"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_settings public.golden_league_settings%rowtype;
  v_question_ids jsonb; v_inserted date;
  v_today date := (now() AT TIME ZONE 'Africa/Cairo')::date;
  v_now time := (now() AT TIME ZONE 'Africa/Cairo')::time;
BEGIN
  SELECT * INTO v_settings FROM public.golden_league_settings WHERE id=1;
  IF NOT FOUND OR NOT v_settings.active THEN RETURN jsonb_build_object('ok',false,'reason','league_inactive'); END IF;
  IF NOT (extract(dow FROM v_today)::integer=ANY(v_settings.allowed_days)) THEN
    RETURN jsonb_build_object('ok',false,'reason','closed_day');
  END IF;
  IF v_now<v_settings.daily_start THEN RETURN jsonb_build_object('ok',false,'reason','not_started'); END IF;
  IF v_now>=v_settings.daily_end THEN RETURN jsonb_build_object('ok',false,'reason','ended'); END IF;
  IF public.golden_league_week_number(v_today)=0 THEN RETURN jsonb_build_object('ok',false,'reason','off_cycle'); END IF;
  IF EXISTS (SELECT 1 FROM public.quiz_daily_sessions WHERE quiz_date=v_today) THEN
    RETURN jsonb_build_object('ok',true,'created',false,'quiz_date',v_today);
  END IF;
  SELECT jsonb_agg(chosen.id ORDER BY chosen.random_key) INTO v_question_ids
  FROM (SELECT q.id,random() random_key FROM public.quiz_bank_questions q
    WHERE q.active IS TRUE ORDER BY random_key LIMIT 5) chosen;
  IF v_question_ids IS NULL OR jsonb_array_length(v_question_ids)<>5 THEN
    RETURN jsonb_build_object('ok',false,'reason','need_five_active_questions');
  END IF;
  INSERT INTO public.quiz_daily_sessions(quiz_date,question_ids) VALUES(v_today,v_question_ids)
    ON CONFLICT(quiz_date) DO NOTHING RETURNING quiz_date INTO v_inserted;
  RETURN jsonb_build_object('ok',true,'created',v_inserted IS NOT NULL,'quiz_date',v_today);
END;
$$;


ALTER FUNCTION "public"."ensure_weekly_quiz_session"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."final_dismiss_student"("p_student_id" "text", "p_decision_number" "text" DEFAULT NULL::"text", "p_action_date" "date" DEFAULT CURRENT_DATE, "p_reason" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_user uuid:=auth.uid(); v_created_by uuid;
begin
 if v_user is null or not exists(select 1 from public.user_profiles where id=v_user and role='admin' and coalesce(is_active,true)) then raise exception 'admin_only'; end if;
 if not exists(select 1 from public.students where id=p_student_id and student_status='dismissed') then raise exception 'dismissed_student_not_found'; end if;
 v_created_by := case when exists(select 1 from public.users where id=v_user) then v_user else null end;
 insert into public.student_disciplinary_actions(student_id,action_type,action_date,decision_number,reason,notes,created_by) values(p_student_id,'final_dismissal',p_action_date,p_decision_number,p_reason,p_notes,v_user);
 update public.students set student_status='final_dismissed',dismissed_at=coalesce(dismissed_at,now()),dismissed_by=v_user where id=p_student_id;
 if v_created_by is not null then
   insert into public.procedures(student_id,type,reference_number,date,details,result,created_by,created_at)
   values(p_student_id,'فصل نهائي',p_decision_number,to_char(p_action_date,'YYYY-MM-DD'),p_reason,p_notes,v_created_by,now());
 else
   insert into public.procedures(student_id,type,reference_number,date,details,result,created_at)
   values(p_student_id,'فصل نهائي',p_decision_number,to_char(p_action_date,'YYYY-MM-DD'),p_reason,p_notes,now());
 end if;
 return jsonb_build_object('success',true,'student_id',p_student_id,'status','final_dismissed');
end $$;


ALTER FUNCTION "public"."final_dismiss_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_portal_notifications"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text" DEFAULT 'student'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE st public.students%rowtype; items jsonb;
BEGIN
  IF p_portal_type NOT IN ('student','parent') OR NOT public.student_face_phone_matches(p_student_id,p_phone) THEN
    RETURN jsonb_build_object('verified',false,'notifications','[]'::jsonb);
  END IF;
  SELECT * INTO st FROM public.students
  WHERE id=btrim(p_student_id) AND deleted_at IS NULL AND coalesce(student_status,'active')='active' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('verified',false,'notifications','[]'::jsonb); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',n.id,'title',n.title,'body',n.body,'notification_type',n.notification_type,
    'priority',n.priority,'created_at',n.created_at,'published_at',n.published_at,
    'metadata',n.metadata,
    'show_on_login',(n.show_on_login IS TRUE OR n.priority='urgent'),
    'is_read',EXISTS(SELECT 1 FROM public.notification_receipts r
      WHERE r.notification_id=n.id AND r.student_id=st.id AND r.portal_type=p_portal_type)
  ) ORDER BY CASE n.priority WHEN 'urgent' THEN 1 WHEN 'high' THEN 2 WHEN 'normal' THEN 3 ELSE 4 END,
    coalesce(n.published_at,n.created_at) DESC),'[]'::jsonb) INTO items
  FROM public.notifications n
  WHERE n.is_published IS TRUE
    AND (n.scheduled_for IS NULL OR n.scheduled_for<=now())
    AND (n.expires_at IS NULL OR n.expires_at>now() OR n.priority='urgent')
    AND (
      n.audience='all'
      OR (n.audience='student' AND p_portal_type='student' AND (n.student_id IS NULL OR n.student_id=st.id))
      OR (n.audience='parent' AND p_portal_type='parent' AND (n.student_id IS NULL OR n.student_id=st.id))
      OR (n.audience='branch' AND n.branch=st.branch)
      OR (n.audience='program' AND n.program=st.program)
    );
  RETURN jsonb_build_object('verified',true,'notifications',items);
END;
$$;


ALTER FUNCTION "public"."get_portal_notifications"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_public_competition"("p_competition_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE c public.competitions%rowtype;
BEGIN
  SELECT * INTO c FROM public.competitions
  WHERE id=p_competition_id AND active IS TRUE
    AND (start_date IS NULL OR start_date <= (now() AT TIME ZONE 'Africa/Cairo')::date)
    AND (end_date IS NULL OR end_date >= (now() AT TIME ZONE 'Africa/Cairo')::date)
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','competition_unavailable'); END IF;
  RETURN jsonb_build_object('ok',true,'competition',jsonb_build_object(
    'id',c.id,'title',c.title,'description',c.description,'branch',c.branch,
    'start_date',c.start_date,'end_date',c.end_date
  ));
END;
$$;


ALTER FUNCTION "public"."get_public_competition"("p_competition_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_public_portal_announcements"("p_portal_type" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare items jsonb;
begin
  if p_portal_type not in ('student','parent') then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',n.id,
    'title',n.title,
    'body',n.body,
    'notification_type',n.notification_type,
    'priority',n.priority,
    'published_at',n.published_at,
    'created_at',n.created_at,
    'metadata',n.metadata
  ) order by case n.priority when 'urgent' then 1 when 'high' then 2 when 'normal' then 3 else 4 end,
    coalesce(n.published_at,n.created_at) desc), '[]'::jsonb)
  into items
  from public.notifications n
  where n.is_published is true
    and (n.scheduled_for is null or n.scheduled_for <= now())
    and (n.expires_at is null or n.expires_at > now())
    and n.student_id is null
    and n.branch is null
    and n.program is null
    and n.audience in ('all',p_portal_type);

  return items;
end;
$$;


ALTER FUNCTION "public"."get_public_portal_announcements"("p_portal_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_public_student_card"("p_student_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  s public.students%rowtype;
  attendance_total integer := 0;
  attendance_present integer := 0;
  total_score numeric := 0;
  total_max numeric := 0;
  session_data jsonb;
BEGIN
  IF coalesce(btrim(p_student_id),'') = '' THEN RETURN NULL; END IF;
  SELECT * INTO s FROM public.students
  WHERE id=btrim(p_student_id) AND deleted_at IS NULL
    AND coalesce(student_status,'active')='active'
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT count(*), count(*) FILTER (WHERE status='حاضر')
  INTO attendance_total, attendance_present
  FROM public.attendance WHERE student_id=s.id;

  SELECT
    coalesce(sum(CASE WHEN g.grade_1 IS NOT NULL THEN g.grade_1 ELSE 0 END),0)
      + coalesce(sum(CASE WHEN g.grade_2 IS NOT NULL THEN g.grade_2 ELSE 0 END),0),
    coalesce(sum(CASE WHEN g.grade_1 IS NOT NULL THEN coalesce(sub.max_grade_1,0) ELSE 0 END),0)
      + coalesce(sum(CASE WHEN g.grade_2 IS NOT NULL THEN coalesce(sub.max_grade_2,0) ELSE 0 END),0)
  INTO total_score,total_max
  FROM public.grades g
  LEFT JOIN public.subjects sub ON sub.id=g.subject_id
  WHERE g.student_id=s.id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'day',x.day,'day_order',x.day_order,'start_time',x.start_time,'end_time',x.end_time,
    'program_name',x.program_name,'program_id',x.program_id,'system_name',x.system_name,
    'subject_name',x.subject_name,'branch',x.branch,'program_combos',x.program_combos,
    'session_date',x.session_date
  ) ORDER BY x.day_order NULLS LAST,x.start_time), '[]'::jsonb)
  INTO session_data
  FROM public.schedule_sessions x
  WHERE x.branch=s.branch;

  RETURN jsonb_build_object(
    'student',jsonb_build_object(
      'id',s.id,'name',s.name,'branch',s.branch,'program',s.program,
      'program_id',s.program_id,'system_name',s.system_name,'photo_url',s.photo_url,'date',s.date
    ),
    'attendance_pct',CASE WHEN attendance_total>0 THEN round(attendance_present::numeric*100/attendance_total)::integer ELSE NULL END,
    'grade_pct',CASE WHEN total_max>0 THEN round(total_score*100/total_max)::integer ELSE NULL END,
    'sessions',session_data
  );
END;
$$;


ALTER FUNCTION "public"."get_public_student_card"("p_student_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_branch"("p_student_id" "text") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT branch FROM students WHERE id = p_student_id;
$$;


ALTER FUNCTION "public"."get_student_branch"("p_student_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_requests"("p_student_id" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  s public.students%rowtype;
  normalized_phone text := public.normalize_eg_phone(p_phone);
  rows_json jsonb;
BEGIN
  IF coalesce(btrim(p_student_id),'') = '' OR normalized_phone = '' THEN
    RETURN jsonb_build_object('verified',false,'requests','[]'::jsonb);
  END IF;

  SELECT st.* INTO s
  FROM public.students st
  WHERE st.id = btrim(p_student_id)
    AND st.deleted_at IS NULL
    AND (
      public.normalize_eg_phone(st.phone) = normalized_phone
      OR public.normalize_eg_phone(st.guardian_phone) = normalized_phone
      OR public.normalize_eg_phone(st.parent_phone) = normalized_phone
    )
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('verified',false,'requests','[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,
    'request_type',r.request_type,
    'title',r.title,
    'description',r.description,
    'priority',r.priority,
    'status',r.status,
    'admin_response',r.admin_response,
    'created_at',r.created_at,
    'updated_at',r.updated_at,
    'resolved_at',r.resolved_at
  ) ORDER BY r.created_at DESC),'[]'::jsonb)
  INTO rows_json
  FROM public.student_requests r
  WHERE r.student_id = s.id
    AND r.student_hidden_at IS NULL;

  RETURN jsonb_build_object('verified',true,'requests',rows_json);
END;
$$;


ALTER FUNCTION "public"."get_student_requests"("p_student_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_summary_catalog"("p_student_id" "text") RETURNS TABLE("id" "uuid", "title" "text", "description" "text", "subject_name" "text", "price" numeric, "validity_days" integer, "is_owned" boolean, "pending_status" "text", "order_id" "uuid", "order_reason" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
WITH package_rows AS (
  SELECT p.id AS package_id,
         min(pi.summary_id::text)::uuid AS representative_id,
         p.name,p.price,p.validity_days,
         EXISTS (
           SELECT 1 FROM public.study_summary_entitlements e
           WHERE e.student_id=p_student_id
             AND e.summary_id=min(pi.summary_id::text)::uuid
             AND e.revoked_at IS NULL AND e.starts_at<=now()
             AND (e.expires_at IS NULL OR e.expires_at>now())
         ) AS all_owned
  FROM public.study_summary_packages p
  JOIN public.study_summary_package_items pi ON pi.package_id=p.id
  WHERE p.is_active=true
  GROUP BY p.id,p.name,p.price,p.validity_days
)
SELECT pr.representative_id,pr.name,
       'تشمل 3 أجزاء: صح وغلط 40 سؤال + اختياري 40 سؤال + مقالي 20 سؤال — بسعر إجمالي 40 ج.م.'::text,
       coalesce((SELECT s.subject_name FROM public.study_summaries s WHERE s.id=pr.representative_id),'اسس التمريض عملى'),
       pr.price,pr.validity_days,pr.all_owned,
       (SELECT o.status FROM public.study_summary_orders o WHERE o.summary_id=pr.representative_id AND o.student_id=p_student_id AND o.admin_deleted_at IS NULL ORDER BY o.created_at DESC LIMIT 1),
       (SELECT o.id FROM public.study_summary_orders o WHERE o.summary_id=pr.representative_id AND o.student_id=p_student_id AND o.admin_deleted_at IS NULL ORDER BY o.created_at DESC LIMIT 1),
       (SELECT o.reviewed_reason FROM public.study_summary_orders o WHERE o.summary_id=pr.representative_id AND o.student_id=p_student_id AND o.admin_deleted_at IS NULL ORDER BY o.created_at DESC LIMIT 1)
FROM package_rows pr
WHERE EXISTS (
  SELECT 1 FROM public.study_summaries s WHERE s.id=pr.representative_id
    AND s.is_published=true AND s.is_approved=true
    AND (s.available_from IS NULL OR s.available_from<=now())
    AND (s.available_until IS NULL OR s.available_until>now())
)
UNION ALL
SELECT s.id,s.title,s.description,s.subject_name,s.price,s.validity_days,
       EXISTS (
         SELECT 1 FROM public.study_summary_entitlements e
         WHERE e.summary_id=s.id AND e.student_id=p_student_id AND e.revoked_at IS NULL
           AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
       ),
       (SELECT o.status FROM public.study_summary_orders o WHERE o.summary_id=s.id AND o.student_id=p_student_id AND o.admin_deleted_at IS NULL ORDER BY o.created_at DESC LIMIT 1),
       (SELECT o.id FROM public.study_summary_orders o WHERE o.summary_id=s.id AND o.student_id=p_student_id AND o.admin_deleted_at IS NULL ORDER BY o.created_at DESC LIMIT 1),
       (SELECT o.reviewed_reason FROM public.study_summary_orders o WHERE o.summary_id=s.id AND o.student_id=p_student_id AND o.admin_deleted_at IS NULL ORDER BY o.created_at DESC LIMIT 1)
FROM public.study_summaries s
WHERE s.is_published=true AND s.is_approved=true
  AND (s.available_from IS NULL OR s.available_from<=now())
  AND (s.available_until IS NULL OR s.available_until>now())
  AND NOT EXISTS (SELECT 1 FROM public.study_summary_package_items pi WHERE pi.summary_id=s.id)
ORDER BY 1;
$$;


ALTER FUNCTION "public"."get_student_summary_catalog"("p_student_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_summary_content"("p_student_id" "text", "p_summary_id" "uuid") RETURNS TABLE("id" "uuid", "title" "text", "description" "text", "subject_name" "text", "material_text" "text", "question_id" "uuid", "question_type" "text", "question_text" "text", "answer_text" "text", "options" "jsonb", "explanation" "text", "order_num" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
select srep.id,coalesce(p.name,srep.title),case when p.id is not null then 'تشمل 3 أجزاء: صح وغلط 40 سؤال + اختياري 40 سؤال + مقالي 20 سؤال — بسعر إجمالي 40 ج.م.' else srep.description end,srep.subject_name,srep.material_text,q.id,q.question_type,q.question_text,q.answer_text,q.options,q.explanation,q.order_num from study_summaries srep left join study_summary_package_items repi on repi.summary_id=srep.id left join study_summary_packages p on p.id=repi.package_id and p.is_active=true join study_summary_questions q on q.summary_id=case when p.id is null then srep.id else q.summary_id end where srep.id=p_summary_id and srep.is_published=true and exists(select 1 from study_summary_entitlements e where e.summary_id=p_summary_id and e.student_id=p_student_id and e.revoked_at is null and (e.expires_at is null or e.expires_at>now())) and q.is_selected=true and q.is_approved=true and (p.id is null or q.summary_id in(select pi3.summary_id from study_summary_package_items pi3 where pi3.package_id=p.id)) order by q.order_num nulls last,q.created_at;
$$;


ALTER FUNCTION "public"."get_student_summary_content"("p_student_id" "text", "p_summary_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_branch"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(branch, 'الكل') FROM user_profiles WHERE id = auth.uid() AND is_active = true;
$$;


ALTER FUNCTION "public"."get_user_branch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(role, 'employee') FROM user_profiles WHERE id = auth.uid() AND is_active = true;
$$;


ALTER FUNCTION "public"."get_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."golden_league_cycle_start"("p_date" "date" DEFAULT (("now"() AT TIME ZONE 'Africa/Cairo'::"text"))::"date") RETURNS "date"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  -- Four-week / 28-day monthly prize cycle, anchored to Saturday 2026-10-31.
  SELECT date '2026-10-31'
    + (floor((p_date - date '2026-10-31')::numeric / 28)::integer * 28);
$$;


ALTER FUNCTION "public"."golden_league_cycle_start"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."golden_league_admin_report"("p_cycle_start" "date" DEFAULT "public"."golden_league_cycle_start"((("now"() AT TIME ZONE 'Africa/Cairo'::"text"))::"date")) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_settings public.golden_league_settings%rowtype; v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=auth.uid() AND up.is_active IS TRUE AND up.role='admin'
  ) THEN RAISE EXCEPTION 'not authorized' USING ERRCODE='42501'; END IF;
  SELECT * INTO v_settings FROM public.golden_league_settings WHERE id=1;
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.qualified DESC,r.total_points DESC,r.student_name),'[]'::jsonb)
  INTO v_result
  FROM (
    SELECT s.id AS student_id,s.name AS student_name,
      coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start),0) AS week1,
      coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start+7),0) AS week2,
      coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start+14),0) AS week3,
      coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start+21),0) AS week4,
      coalesce(sum(q.total_points),0) AS total_points,
      (coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start),0)>=v_settings.weekly_thresholds[1]
       AND coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start+7),0)>=v_settings.weekly_thresholds[2]
       AND coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start+14),0)>=v_settings.weekly_thresholds[3]
       AND coalesce(max(q.total_points) FILTER(WHERE q.week_start=p_cycle_start+21),0)>=v_settings.weekly_thresholds[4]) AS qualified
    FROM public.students s
    LEFT JOIN public.quiz_weekly_scores q ON q.student_id=s.id AND q.week_start>=p_cycle_start AND q.week_start<p_cycle_start+28
    WHERE s.deleted_at IS NULL AND s.student_status='active'
    GROUP BY s.id,s.name
    HAVING coalesce(sum(q.total_points),0)>0
  ) r;
  RETURN jsonb_build_object('ok',true,'cycle_start',p_cycle_start,'leaderboard',v_result);
END;
$$;


ALTER FUNCTION "public"."golden_league_admin_report"("p_cycle_start" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."golden_league_get_settings_admin"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE s public.golden_league_settings%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=auth.uid() AND up.is_active IS TRUE AND up.role='admin'
  ) THEN RAISE EXCEPTION 'not authorized' USING ERRCODE='42501'; END IF;
  SELECT * INTO s FROM public.golden_league_settings WHERE id=1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','settings_missing'); END IF;
  RETURN jsonb_build_object('ok',true,'settings',jsonb_build_object(
    'daily_start',s.daily_start,'daily_end',s.daily_end,'questions_per_day',s.questions_per_day,
    'points_per_question',s.points_per_question,'weekly_thresholds',s.weekly_thresholds,
    'weekly_seconds',s.weekly_seconds,'active',s.active,'timezone',s.timezone));
END;
$$;


ALTER FUNCTION "public"."golden_league_get_settings_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."golden_league_get_student_dashboard"("p_student_id" "text", "p_face_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_student public.students%rowtype;
  v_settings public.golden_league_settings%rowtype;
  v_today date := (now() AT TIME ZONE 'Africa/Cairo')::date;
  v_now time := (now() AT TIME ZONE 'Africa/Cairo')::time;
  v_cycle date; v_week integer; v_week_start date; v_threshold integer; v_seconds integer;
  v_my_week integer:=0; v_month integer:=0; v_correct integer:=0; v_week_breakdown jsonb; v_completed_weeks integer:=0;
  v_board jsonb; v_week_board jsonb; v_window text; v_eligible boolean:=true; v_i integer; v_points integer;
BEGIN
  SELECT * INTO v_student FROM public.students WHERE id=btrim(coalesce(p_student_id,'')) AND deleted_at IS NULL AND student_status='active';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','student_not_found'); END IF;
  IF p_face_token IS NULL OR NOT (
    EXISTS (SELECT 1 FROM public.competition_face_verified_sessions s WHERE s.token=p_face_token
      AND s.student_id=v_student.id AND s.competition_type='weekly_quiz' AND s.expires_at>now()
      AND coalesce(s.verification_method,'') IN ('device','passkey','device_passkey'))
    OR EXISTS (SELECT 1 FROM public.weekly_quiz_access_audit a WHERE a.student_id=v_student.id
      AND split_part(a.photo_path,'/',3)=p_face_token::text AND a.photo_consent_at IS NOT NULL
      AND a.entered_at>=now()-interval '30 minutes')
  ) THEN RETURN jsonb_build_object('ok',false,'reason','face_verification_required'); END IF;
  SELECT * INTO v_settings FROM public.golden_league_settings WHERE id=1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','settings_missing'); END IF;
  v_cycle:=public.golden_league_cycle_start(v_today);
  v_week:=public.golden_league_week_number(v_today);
  v_week_start:=CASE WHEN v_week BETWEEN 1 AND 4 THEN v_cycle+(v_week-1)*7 ELSE NULL END;
  v_threshold:=CASE WHEN v_week BETWEEN 1 AND 4 THEN v_settings.weekly_thresholds[v_week] ELSE 0 END;
  v_seconds:=CASE WHEN v_week BETWEEN 1 AND 4 THEN v_settings.weekly_seconds[v_week] ELSE 0 END;
  IF NOT v_settings.active OR v_week=0 THEN v_window:='off_cycle';
  ELSIF NOT (extract(dow FROM v_today)::integer=ANY(v_settings.allowed_days)) THEN v_window:='closed_day';
  ELSIF v_now<v_settings.daily_start THEN v_window:='not_started';
  ELSIF v_now>=v_settings.daily_end THEN v_window:='ended';
  ELSE v_window:='open'; END IF;

  IF v_week BETWEEN 1 AND 4 THEN
    SELECT coalesce(sum(points_earned),0),count(*) FILTER(WHERE is_correct)
      INTO v_my_week,v_correct FROM public.quiz_answers
      WHERE student_id=v_student.id AND quiz_date>=v_week_start AND quiz_date<v_week_start+7;
    SELECT coalesce(sum(total_points),0) INTO v_month FROM public.quiz_weekly_scores
      WHERE student_id=v_student.id AND week_start>=v_cycle AND week_start<v_cycle+28;
    v_month:=v_month+v_my_week-COALESCE((SELECT total_points FROM public.quiz_weekly_scores
      WHERE student_id=v_student.id AND week_start=v_week_start),0);
  ELSE
    SELECT coalesce(sum(total_points),0) INTO v_month FROM public.quiz_weekly_scores
      WHERE student_id=v_student.id AND week_start>=v_cycle AND week_start<v_cycle+28;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object('week',w,'points',coalesce(q.total_points,0),
    'threshold',v_settings.weekly_thresholds[w],'qualified',coalesce(q.total_points,0)>=v_settings.weekly_thresholds[w])
    ORDER BY w),'[]'::jsonb)
  INTO v_week_breakdown
  FROM generate_series(1,4) w
  LEFT JOIN public.quiz_weekly_scores q ON q.student_id=v_student.id AND q.week_start=v_cycle+(w-1)*7;

  v_completed_weeks:=CASE
    WHEN v_week=0 AND v_today>=v_cycle+28 THEN 4
    WHEN v_week BETWEEN 1 AND 4 THEN greatest(0,v_week-1)+CASE WHEN v_today>=v_week_start+6 THEN 1 ELSE 0 END
    ELSE 0 END;
  FOR v_i IN 1..v_completed_weeks LOOP
    SELECT coalesce(total_points,0) INTO v_points FROM public.quiz_weekly_scores
      WHERE student_id=v_student.id AND week_start=v_cycle+(v_i-1)*7;
    IF coalesce(v_points,0)<v_settings.weekly_thresholds[v_i] THEN v_eligible:=false; END IF;
  END LOOP;

  SELECT coalesce(jsonb_agg(jsonb_build_object('rank',r.rn,'student_name',r.student_name,
    'total_points',r.month_points,'week_points',r.week_points,'is_me',r.student_id=v_student.id,
    'eligible',r.eligible) ORDER BY r.rn),'[]'::jsonb)
  INTO v_board
  FROM (
    SELECT row_number() OVER(ORDER BY CASE WHEN v_completed_weeks=4 THEN a.eligible ELSE true END DESC,a.month_points DESC,a.week_points DESC,a.student_name) rn,
      a.student_id,a.student_name,a.month_points,a.week_points,a.eligible
    FROM (
      SELECT s.id student_id,s.name student_name,
        (SELECT coalesce(sum(q.total_points),0) FROM public.quiz_weekly_scores q
          WHERE q.student_id=s.id AND q.week_start>=v_cycle AND q.week_start<v_cycle+28) +
        CASE WHEN v_week BETWEEN 1 AND 4 THEN
          coalesce((SELECT sum(qa.points_earned) FROM public.quiz_answers qa
            WHERE qa.student_id=s.id AND qa.quiz_date>=v_week_start AND qa.quiz_date<v_week_start+7),0) -
          coalesce((SELECT q2.total_points FROM public.quiz_weekly_scores q2
            WHERE q2.student_id=s.id AND q2.week_start=v_week_start),0)
        ELSE 0 END AS month_points,
        CASE WHEN v_week BETWEEN 1 AND 4 THEN
          coalesce((SELECT sum(qa.points_earned) FROM public.quiz_answers qa
            WHERE qa.student_id=s.id AND qa.quiz_date>=v_week_start AND qa.quiz_date<v_week_start+7),0)
        ELSE 0 END AS week_points,
        NOT EXISTS (
          SELECT 1 FROM generate_series(1,v_completed_weeks) w
          WHERE (SELECT coalesce(q3.total_points,0) FROM public.quiz_weekly_scores q3
            WHERE q3.student_id=s.id AND q3.week_start=v_cycle+(w-1)*7)
            < v_settings.weekly_thresholds[w]
        ) AS eligible
      FROM public.students s WHERE s.deleted_at IS NULL AND s.student_status='active'
        AND EXISTS (SELECT 1 FROM public.quiz_answers qa0 WHERE qa0.student_id=s.id
          AND qa0.quiz_date>=v_cycle AND qa0.quiz_date<v_cycle+28)
    ) a
  ) r WHERE (r.rn<=50 OR r.student_id=v_student.id) AND (v_completed_weeks<4 OR r.eligible);

  SELECT coalesce(jsonb_agg(jsonb_build_object('rank',r.rn,'student_name',r.student_name,
    'total_points',r.total_points,'correct_count',r.correct_count,'is_me',r.student_id=v_student.id)
    ORDER BY r.rn),'[]'::jsonb)
  INTO v_week_board
  FROM (
    SELECT row_number() OVER(ORDER BY q.total_points DESC,q.correct_count DESC,q.student_name) rn,
      q.student_id,q.student_name,q.total_points,q.correct_count
    FROM public.quiz_weekly_scores q
    WHERE q.week_start=v_cycle+(v_week-1)*7
    ORDER BY q.total_points DESC,q.correct_count DESC,q.student_name
  ) r WHERE r.rn<=10 OR r.student_id=v_student.id;

  RETURN jsonb_build_object('ok',true,'cycle_start',v_cycle,'week_number',v_week,
    'week_start',v_week_start,'week_points',v_my_week,'month_points',v_month,
    'correct_count',v_correct,'weekly_threshold',v_threshold,'question_seconds',v_seconds,
    'week_breakdown',v_week_breakdown,'eligible',v_eligible,'window_status',v_window,
    'daily_start',v_settings.daily_start,'daily_end',v_settings.daily_end,
    'questions_per_day',v_settings.questions_per_day,'points_per_question',v_settings.points_per_question,
    'leaderboard',v_board,'weekly_leaderboard',v_week_board);
END;
$$;


ALTER FUNCTION "public"."golden_league_get_student_dashboard"("p_student_id" "text", "p_face_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."golden_league_update_settings"("p_daily_start" "text" DEFAULT '19:00'::"text", "p_daily_end" "text" DEFAULT '20:00'::"text", "p_questions_per_day" integer DEFAULT 5, "p_points_per_question" integer DEFAULT 10, "p_weekly_thresholds" integer[] DEFAULT ARRAY[200, 230, 260, 280], "p_weekly_seconds" integer[] DEFAULT ARRAY[20, 15, 10, 5]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_start time; v_end time;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id=auth.uid() AND up.is_active IS TRUE AND up.role='admin'
  ) THEN RAISE EXCEPTION 'not authorized' USING ERRCODE='42501'; END IF;
  IF p_questions_per_day<>5 OR p_points_per_question<>10
     OR cardinality(p_weekly_thresholds)<>4 OR cardinality(p_weekly_seconds)<>4
     OR EXISTS (SELECT 1 FROM unnest(p_weekly_thresholds) x WHERE x<0 OR x>300)
     OR EXISTS (SELECT 1 FROM unnest(p_weekly_seconds) x WHERE x<1 OR x>60)
  THEN RETURN jsonb_build_object('ok',false,'reason','invalid_league_settings'); END IF;
  BEGIN v_start:=p_daily_start::time; v_end:=p_daily_end::time;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('ok',false,'reason','invalid_time'); END;
  IF v_start>=v_end THEN RETURN jsonb_build_object('ok',false,'reason','invalid_time_window'); END IF;
  UPDATE public.golden_league_settings SET daily_start=v_start,daily_end=v_end,
    questions_per_day=5,points_per_question=10,
    weekly_thresholds=p_weekly_thresholds,weekly_seconds=p_weekly_seconds,updated_at=now()
  WHERE id=1;
  RETURN jsonb_build_object('ok',true);
END;
$$;


ALTER FUNCTION "public"."golden_league_update_settings"("p_daily_start" "text", "p_daily_end" "text", "p_questions_per_day" integer, "p_points_per_question" integer, "p_weekly_thresholds" integer[], "p_weekly_seconds" integer[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."golden_league_week_number"("p_date" "date") RETURNS integer
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public'
    AS $$
  SELECT CASE
    WHEN p_date < public.golden_league_cycle_start(p_date)
      OR p_date >= public.golden_league_cycle_start(p_date) + 28 THEN 0
    ELSE ((p_date - public.golden_league_cycle_start(p_date)) / 7) + 1
  END;
$$;


ALTER FUNCTION "public"."golden_league_week_number"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_username TEXT;
  v_full_name TEXT;
BEGIN
  v_username := COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1));
  v_full_name := NEW.raw_user_meta_data->>'full_name';
  
  INSERT INTO public.user_profiles (id, username, full_name, role, branch)
  VALUES (
    NEW.id,
    v_username,
    v_full_name,
    COALESCE(NEW.raw_user_meta_data->>'role', 'employee'),
    COALESCE(NEW.raw_user_meta_data->>'branch', 'الكل')
  )
  ON CONFLICT (id) DO NOTHING;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_active_user"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM user_profiles
    WHERE id = auth.uid() AND is_active = true
  );
$$;


ALTER FUNCTION "public"."is_active_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM user_profiles
    WHERE id = auth.uid() AND role = 'admin' AND is_active = true
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_portal_notification_read"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text", "p_notification_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE st public.students%rowtype;
BEGIN
  IF p_portal_type NOT IN ('student','parent')
     OR NOT public.student_face_phone_matches(p_student_id,p_phone) THEN
    RETURN jsonb_build_object('ok',false,'reason','identity_not_verified');
  END IF;
  SELECT * INTO st FROM public.students
  WHERE id=btrim(p_student_id) AND deleted_at IS NULL
    AND coalesce(student_status,'active')='active'
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','student_unavailable'); END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.notifications n
    WHERE n.id=p_notification_id
      AND (n.show_on_login IS TRUE OR n.priority='urgent')
      AND n.is_published IS TRUE
      AND (n.scheduled_for IS NULL OR n.scheduled_for<=now())
      AND (n.expires_at IS NULL OR n.expires_at>now())
      AND (
        n.audience='all'
        OR (n.audience='student' AND p_portal_type='student' AND (n.student_id IS NULL OR n.student_id=st.id))
        OR (n.audience='parent' AND p_portal_type='parent' AND (n.student_id IS NULL OR n.student_id=st.id))
        OR (n.audience='branch' AND n.branch=st.branch)
        OR (n.audience='program' AND n.program=st.program)
      )
  ) THEN
    RETURN jsonb_build_object('ok',false,'reason','notification_unavailable');
  END IF;

  INSERT INTO public.notification_receipts(notification_id,student_id,portal_type,read_at)
  VALUES (p_notification_id,st.id,p_portal_type,now())
  ON CONFLICT (notification_id,student_id,portal_type) DO UPDATE SET read_at=excluded.read_at;
  RETURN jsonb_build_object('ok',true);
END;
$$;


ALTER FUNCTION "public"."mark_portal_notification_read"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text", "p_notification_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_eg_phone"("p_phone" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  WITH d AS (SELECT regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g') AS v)
  SELECT CASE
    WHEN v LIKE '0020%' THEN '0' || substr(v, 5)
    WHEN v LIKE '20%' AND length(v) = 12 THEN '0' || substr(v, 3)
    WHEN v LIKE '1%' AND length(v) = 10 THEN '0' || v
    ELSE v
  END
  FROM d;
$$;


ALTER FUNCTION "public"."normalize_eg_phone"("p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_student_login_digits"("p_value" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'public'
    AS $$
  SELECT translate(
    coalesce(p_value, ''),
    '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
    '01234567890123456789'
  );
$$;


ALTER FUNCTION "public"."normalize_student_login_digits"("p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."parent_portal_get_data"("p_student_id" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  s public.students%rowtype;
  phone_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  normalized_phone text;
  v_week_start date;
  v_program_fees numeric;
BEGIN
  normalized_phone := CASE
    WHEN phone_digits LIKE '0020%' THEN '0' || substr(phone_digits, 5)
    WHEN phone_digits LIKE '20%' AND length(phone_digits) = 12 THEN '0' || substr(phone_digits, 3)
    WHEN phone_digits LIKE '1%' AND length(phone_digits) = 10 THEN '0' || phone_digits
    ELSE phone_digits
  END;

  IF coalesce(btrim(p_student_id), '') = '' OR normalized_phone = '' THEN
    RETURN jsonb_build_object('student', null);
  END IF;

  SELECT * INTO s
  FROM public.students st
  WHERE st.id = btrim(p_student_id)
    AND (
      (CASE
        WHEN regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g'), 5)
        WHEN regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g'), 3)
        WHEN regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')
        ELSE regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')
      END) = normalized_phone
      OR
      (CASE
        WHEN regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g'), 5)
        WHEN regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g'), 3)
        WHEN regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')
        ELSE regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')
      END) = normalized_phone
      OR
      (CASE
        WHEN regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g'), 5)
        WHEN regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g'), 3)
        WHEN regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')
        ELSE regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')
      END) = normalized_phone
    )
  LIMIT 1;

  IF NOT FOUND THEN RETURN jsonb_build_object('student', null); END IF;

  SELECT p.fees INTO v_program_fees
  FROM public.programs p WHERE p.id = s.program_id LIMIT 1;
  v_week_start := (current_date - ((extract(dow from current_date)::integer + 1) % 7))::date; -- أسبوع المسابقة يبدأ يوم السبت

  RETURN jsonb_build_object(
    'student', jsonb_build_object(
      'id', s.id,
      'name', s.name,
      'age', s.age,
      'edu', s.edu,
      'phone', s.phone,
      'guardian_name', s.guardian_name,
      'guardian_phone', s.guardian_phone,
      'branch', s.branch,
      'program_id', s.program_id,
      'program', s.program,
      'system_name', s.system_name,
      'date', s.date,
      'photo_url', s.photo_url,
      'enrollment_number', s.enrollment_number,
      'enrollment_date', s.enrollment_date,
      'qualification', s.qualification,
      'parent_name', s.parent_name,
      'total_due', s.total_due,
      'blood_type', s.blood_type
    ),
    'program_fees', v_program_fees,
    'attendance', coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM public.attendance a WHERE a.student_id = s.id), '[]'::jsonb),
    'sessions', coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id) FROM public.schedule_sessions x WHERE x.branch = s.branch), '[]'::jsonb),
    'grades', coalesce((SELECT jsonb_agg(to_jsonb(g) ORDER BY g.id) FROM public.grades g WHERE g.student_id = s.id), '[]'::jsonb),
    'payments', coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.payments p WHERE p.student_id = s.id), '[]'::jsonb),
    'evaluations', coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.date DESC) FROM public.student_evaluations e WHERE e.student_id = s.id), '[]'::jsonb),
    'achievements', coalesce((SELECT jsonb_agg(to_jsonb(sa) ORDER BY sa.achievement_date DESC, sa.created_at DESC) FROM public.student_achievements sa WHERE sa.student_id = s.id), '[]'::jsonb),
    'exam_attempts', coalesce((
      SELECT jsonb_agg(
        jsonb_set(to_jsonb(ea), '{exams}',
          coalesce((SELECT jsonb_build_object('title', ex.title, 'total_score', ex.total_score) FROM public.exams ex WHERE ex.id = ea.exam_id), '{}'::jsonb),
          true
        ) ORDER BY ea.submitted_at DESC
      )
      FROM public.exam_attempts ea
      WHERE ea.student_id = s.id AND ea.status = 'submitted'
    ), '[]'::jsonb),
    'weekly_score', coalesce((SELECT to_jsonb(q) FROM public.quiz_weekly_scores q WHERE q.student_id = s.id AND q.week_start = v_week_start LIMIT 1), 'null'::jsonb),
    'procedures', coalesce((SELECT jsonb_agg(to_jsonb(pr) ORDER BY pr.date DESC NULLS LAST, pr.created_at DESC) FROM public.procedures pr WHERE pr.student_id = s.id), '[]'::jsonb),
    'subjects', coalesce((SELECT jsonb_agg(to_jsonb(subj) ORDER BY subj.name) FROM public.subjects subj), '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."parent_portal_get_data"("p_student_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."public_student_lookup"("p_student_id" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE s public.students%rowtype;
BEGIN
  IF coalesce(btrim(p_student_id),'') = '' OR coalesce(btrim(p_phone),'') = ''
     OR NOT public.student_face_phone_matches(p_student_id,p_phone) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO s FROM public.students
  WHERE id = btrim(p_student_id) AND deleted_at IS NULL
    AND coalesce(student_status,'active') = 'active'
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'id',s.id,'name',s.name,'branch',s.branch,'program_id',s.program_id,
    'program',s.program,'system_name',s.system_name,'photo_url',s.photo_url,'date',s.date
  );
END;
$$;


ALTER FUNCTION "public"."public_student_lookup"("p_student_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."require_competition_face_verification"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  expected_type text;
  expected_competition text;
  valid_session boolean;
begin
  if tg_table_name = 'quiz_answers' then
    expected_type := 'weekly_quiz';
    expected_competition := null;
  elsif tg_table_name = 'competition_entries' then
    expected_type := 'public_competition';
    expected_competition := new.competition_id::text;
  else
    raise exception 'Unsupported table for face verification';
  end if;

  select exists (
    select 1
    from public.competition_face_verified_sessions s
    where s.token = new.face_verification_token
      and s.student_id = new.student_id
      and s.competition_type = expected_type
      and s.expires_at > now()
      and (expected_type = 'weekly_quiz' or s.competition_id = expected_competition)
  ) into valid_session;

  if not valid_session then
    raise exception 'Face verification required before submitting competition activity'
      using errcode = '42501';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."require_competition_face_verification"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_dismissed_student"("p_student_id" "text", "p_decision_number" "text" DEFAULT NULL::"text", "p_action_date" "date" DEFAULT CURRENT_DATE, "p_reason" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_user uuid:=auth.uid(); v_created_by uuid;
begin
 if v_user is null or not exists(select 1 from public.user_profiles where id=v_user and role='admin' and coalesce(is_active,true)) then raise exception 'admin_only'; end if;
 if not exists(select 1 from public.students where id=p_student_id and student_status='dismissed') then raise exception 'dismissed_student_not_found'; end if;
 v_created_by := case when exists(select 1 from public.users where id=v_user) then v_user else null end;
 insert into public.student_disciplinary_actions(student_id,action_type,action_date,decision_number,reason,notes,created_by) values(p_student_id,'grievance_restore',p_action_date,p_decision_number,p_reason,p_notes,v_user);
 update public.students set student_status='active',dismissed_at=null,dismissed_by=null where id=p_student_id;
 if v_created_by is not null then
   insert into public.procedures(student_id,type,reference_number,date,details,result,created_by,created_at)
   values(p_student_id,'قرار تظلم / استعادة',p_decision_number,to_char(p_action_date,'YYYY-MM-DD'),p_reason,p_notes,v_created_by,now());
 else
   insert into public.procedures(student_id,type,reference_number,date,details,result,created_at)
   values(p_student_id,'قرار تظلم / استعادة',p_decision_number,to_char(p_action_date,'YYYY-MM-DD'),p_reason,p_notes,now());
 end if;
 return jsonb_build_object('success',true,'student_id',p_student_id,'status','active');
end $$;


ALTER FUNCTION "public"."restore_dismissed_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_ai_admin_dashboard"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not coalesce(public.is_admin(), false) then
    return jsonb_build_object('ok',false,'reason','not_admin');
  end if;
  return jsonb_build_object(
    'ok',true,
    'students',coalesce((select jsonb_agg(to_jsonb(s) order by s.name) from public.students s where s.deleted_at is null), '[]'::jsonb),
    'access',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from public.student_ai_access a), '[]'::jsonb),
    'sessions',coalesce((select jsonb_agg(to_jsonb(x) order by x.last_heartbeat_at desc) from public.student_ai_sessions x), '[]'::jsonb),
    'usage',coalesce((select jsonb_agg(to_jsonb(u) order by u.usage_date desc) from public.student_ai_usage_daily u), '[]'::jsonb),
    'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.student_ai_orders o), '[]'::jsonb),
    'plan',coalesce((select to_jsonb(p) from public.student_ai_plans p where p.code='student_ai_monthly' limit 1), '{}'::jsonb)
  );
end;
$$;


ALTER FUNCTION "public"."student_ai_admin_dashboard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_ai_admin_grant_access"("p_student_id" "text", "p_days" integer DEFAULT 30) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_start timestamptz := now();
  v_exp timestamptz;
  v_access public.student_ai_access%rowtype;
begin
  if not coalesce(public.is_admin(), false) then
    return jsonb_build_object('ok',false,'reason','not_admin');
  end if;
  if p_student_id is null or btrim(p_student_id) = '' then
    return jsonb_build_object('ok',false,'reason','student_required');
  end if;
  if not exists (select 1 from public.students s where s.id=p_student_id and coalesce(s.student_status,'active') <> 'dismissed') then
    return jsonb_build_object('ok',false,'reason','student_not_found');
  end if;
  if p_days < 1 or p_days > 3650 then
    return jsonb_build_object('ok',false,'reason','invalid_days');
  end if;
  update public.student_ai_access
  set status='expired'
  where student_id=p_student_id and status='active' and expires_at <= now();
  update public.student_ai_access
  set status='revoked'
  where student_id=p_student_id and status='active';
  v_exp := v_start + make_interval(days => p_days);
  insert into public.student_ai_access(student_id,access_type,starts_at,expires_at,status,order_id)
  values(p_student_id,'subscription',v_start,v_exp,'active',null)
  returning * into v_access;
  return jsonb_build_object('ok',true,'access_id',v_access.id,'starts_at',v_access.starts_at,'expires_at',v_access.expires_at);
end;
$$;


ALTER FUNCTION "public"."student_ai_admin_grant_access"("p_student_id" "text", "p_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_ai_admin_list_orders"() RETURNS TABLE("id" "uuid", "student_id" "text", "student_name" "text", "enrollment_number" "text", "amount" numeric, "status" "text", "payment_reference" "text", "order_code" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ begin if not coalesce(public.is_admin(),false) then raise exception 'not_admin'; end if; return query select o.id,o.student_id,s.name,s.enrollment_number,o.amount,o.status,o.payment_reference,o.order_code,o.created_at from public.student_ai_orders o join public.students s on s.id=o.student_id where o.hidden_from_student=false order by o.created_at desc limit 200; end; $$;


ALTER FUNCTION "public"."student_ai_admin_list_orders"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_ai_admin_revoke_access"("p_student_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_count integer;
begin
  if not coalesce(public.is_admin(), false) then
    return jsonb_build_object('ok',false,'reason','not_admin');
  end if;
  update public.student_ai_access
  set status='revoked', expires_at=least(expires_at, now())
  where student_id=p_student_id and status='active';
  get diagnostics v_count = row_count;
  return jsonb_build_object('ok',true,'revoked_count',v_count);
end;
$$;


ALTER FUNCTION "public"."student_ai_admin_revoke_access"("p_student_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_ai_admin_subscription_report"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_plan jsonb;
  v_subs jsonb;
  v_orders jsonb;
begin
  if not coalesce(public.is_admin(),false) then
    return jsonb_build_object('ok',false,'reason','not_admin');
  end if;
  select coalesce(to_jsonb(p),'{}'::jsonb) into v_plan
  from public.student_ai_plans p where p.code='student_ai_monthly' limit 1;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.starts_at desc),'[]'::jsonb) into v_subs
  from (
    select a.id,a.student_id,s.name student_name,s.enrollment_number,a.access_type,a.starts_at,a.expires_at,a.status,a.order_id,a.created_at,
           o.amount,o.payment_method,o.payment_reference,o.order_code,o.status order_status,o.reviewed_at,o.reviewed_reason
    from public.student_ai_access a
    join public.students s on s.id=a.student_id
    left join public.student_ai_orders o on o.id=a.order_id
    where s.deleted_at is null
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_orders
  from (
    select o.id,o.student_id,s.name student_name,s.enrollment_number,o.amount,o.status,o.payment_method,o.payment_reference,o.payment_proof_path,o.order_code,o.created_at,o.updated_at,o.reviewed_at,o.reviewed_reason,o.hidden_from_student
    from public.student_ai_orders o
    join public.students s on s.id=o.student_id
    where s.deleted_at is null
  ) x;

  return jsonb_build_object('ok',true,'plan',v_plan,'subscriptions',v_subs,'orders',v_orders);
end;
$$;


ALTER FUNCTION "public"."student_ai_admin_subscription_report"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_ai_approve_order"("p_order_id" "uuid", "p_reviewer" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  o public.student_ai_orders%rowtype;
  a public.student_ai_access%rowtype;
  v_start timestamptz := now();
  v_exp timestamptz;
begin
  if not coalesce(public.is_admin(),false) then
    return jsonb_build_object('ok',false,'reason','not_admin');
  end if;

  select * into o
  from public.student_ai_orders
  where id=p_order_id
  for update;

  if not found then
    return jsonb_build_object('ok',false,'reason','order_not_found');
  end if;

  if o.status <> 'payment_submitted'
     or nullif(btrim(coalesce(o.payment_reference,'')),'') is null then
    return jsonb_build_object('ok',false,'reason','payment_reference_required');
  end if;

  update public.student_ai_access
  set status='expired'
  where student_id=o.student_id and status='active' and expires_at<=v_start;

  update public.student_ai_access
  set status='revoked', expires_at=least(expires_at,v_start)
  where student_id=o.student_id and status='active';

  v_exp:=v_start+interval '30 days';

  update public.student_ai_orders
  set status='approved',
      reviewed_by=coalesce(p_reviewer,auth.uid()),
      reviewed_at=v_start,
      updated_at=v_start,
      hidden_from_student=true
  where id=o.id;

  insert into public.student_ai_access
    (student_id,access_type,starts_at,expires_at,status,order_id)
  values
    (o.student_id,'subscription',v_start,v_exp,'active',o.id)
  returning * into a;

  return jsonb_build_object(
    'ok',true,'access_id',a.id,'starts_at',a.starts_at,
    'expires_at',a.expires_at,'order_id',o.id
  );
end;
$$;


ALTER FUNCTION "public"."student_ai_approve_order"("p_order_id" "uuid", "p_reviewer" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_ai_reject_order"("p_order_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_order public.student_ai_orders%rowtype;
begin
  if not coalesce(public.is_admin(), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;

  select * into v_order
  from public.student_ai_orders
  where id = p_order_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;

  if v_order.status not in ('pending_payment', 'payment_submitted') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_status');
  end if;

  update public.student_ai_orders
  set status = 'rejected',
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      reviewed_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 500),
      updated_at = now()
  where id = p_order_id;

  return jsonb_build_object('ok', true, 'status', 'rejected');
end;
$$;


ALTER FUNCTION "public"."student_ai_reject_order"("p_order_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_create_paid_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_student_id text;
  v_summary public.study_summaries%rowtype;
  v_order public.study_summary_orders%rowtype;
  v_package_id uuid;
  v_rep_id uuid;
  v_package public.study_summary_packages%rowtype;
BEGIN
  SELECT s.student_id INTO v_student_id
  FROM public.competition_face_verified_sessions s
  JOIN public.students st ON st.id=s.student_id
  WHERE s.token=p_session_token AND s.competition_type='student_portal'
    AND s.expires_at>now() AND st.deleted_at IS NULL
    AND coalesce(st.student_status,'active')='active'
  LIMIT 1;
  IF v_student_id IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','session_expired'); END IF;

  SELECT pi.package_id INTO v_package_id
  FROM public.study_summary_package_items pi WHERE pi.summary_id=p_summary_id LIMIT 1;

  IF v_package_id IS NOT NULL THEN
    SELECT * INTO v_package FROM public.study_summary_packages WHERE id=v_package_id AND is_active=true;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','summary_unavailable'); END IF;
    SELECT min(summary_id::text)::uuid INTO v_rep_id FROM public.study_summary_package_items WHERE package_id=v_package_id;
    IF p_summary_id<>v_rep_id THEN RETURN jsonb_build_object('ok',false,'reason','package_only'); END IF;

    IF EXISTS (
      SELECT 1 FROM public.study_summary_entitlements e
      WHERE e.student_id=v_student_id AND e.summary_id=v_rep_id
        AND e.revoked_at IS NULL AND e.starts_at<=now()
        AND (e.expires_at IS NULL OR e.expires_at>now())
    ) THEN
      UPDATE public.study_summary_orders o
      SET status='cancelled', reviewed_at=now(), updated_at=now(),
          reviewed_reason='إلغاء تلقائي: الطالب لديه إتاحة فعالة للباقة بالفعل'
      WHERE o.student_id=v_student_id AND o.summary_id=v_rep_id
        AND o.status='pending_payment' AND o.admin_deleted_at IS NULL;
      RETURN jsonb_build_object('ok',false,'reason','already_has_access');
    END IF;

    SELECT * INTO v_summary FROM public.study_summaries sm
    WHERE sm.id=v_rep_id AND sm.is_published=true AND sm.is_approved=true
      AND (sm.available_from IS NULL OR sm.available_from<=now())
      AND (sm.available_until IS NULL OR sm.available_until>now());
    IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','summary_unavailable'); END IF;
    IF nullif(btrim(v_summary.payment_provider),'') IS NULL OR nullif(btrim(v_summary.payment_wallet_number),'') IS NULL THEN
      RETURN jsonb_build_object('ok',false,'reason','payment_not_configured');
    END IF;

    UPDATE public.study_summary_orders SET status='expired',updated_at=now()
    WHERE student_id=v_student_id AND summary_id=v_rep_id AND status='pending_payment'
      AND expires_at IS NOT NULL AND expires_at<=now();
    SELECT * INTO v_order FROM public.study_summary_orders
    WHERE student_id=v_student_id AND summary_id=v_rep_id AND status='pending_payment'
      AND (expires_at IS NULL OR expires_at>now()) ORDER BY created_at DESC LIMIT 1;
    IF NOT FOUND THEN
      INSERT INTO public.study_summary_orders(student_id,summary_id,amount,status,payment_method,payment_number,order_code,expires_at,access_hours)
      VALUES(v_student_id,v_rep_id,v_package.price,'pending_payment',v_summary.payment_provider,v_summary.payment_wallet_number,
        'AND-SUM-PKG-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)),now()+interval '24 hours',NULL)
      RETURNING * INTO v_order;
      INSERT INTO public.study_summary_activity(student_id,summary_id,order_id,event_type,metadata)
      VALUES(v_student_id,v_rep_id,v_order.id,'order_created',jsonb_build_object('amount',v_order.amount,'status',v_order.status,
        'order_code',v_order.order_code,'package_id',v_package_id));
    END IF;
    RETURN jsonb_build_object('ok',true,'order',jsonb_build_object('id',v_order.id,'order_number',v_order.order_code,
      'order_code',v_order.order_code,'summary_id',v_order.summary_id,'amount',v_order.amount,'status',v_order.status,
      'created_at',v_order.created_at,'expires_at',v_order.expires_at,'payment_provider',v_summary.payment_provider,
      'payment_wallet_number',v_summary.payment_wallet_number,'package_name',v_package.name));
  END IF;

  SELECT * INTO v_summary FROM public.study_summaries sm
  WHERE sm.id=p_summary_id AND sm.is_published=true AND sm.is_approved=true
    AND (sm.available_from IS NULL OR sm.available_from<=now())
    AND (sm.available_until IS NULL OR sm.available_until>now());
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','summary_unavailable'); END IF;
  IF NOT EXISTS(SELECT 1 FROM public.study_summary_questions q WHERE q.summary_id=p_summary_id AND q.is_selected=true AND q.is_approved=true) THEN
    RETURN jsonb_build_object('ok',false,'reason','empty_summary');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.study_summary_entitlements e
    WHERE e.student_id=v_student_id AND e.summary_id=p_summary_id AND e.revoked_at IS NULL
      AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
  ) THEN
    UPDATE public.study_summary_orders o
    SET status='cancelled', reviewed_at=now(), updated_at=now(),
        reviewed_reason='إلغاء تلقائي: الطالب لديه إتاحة فعالة للملخص بالفعل'
    WHERE o.student_id=v_student_id AND o.summary_id=p_summary_id
      AND o.status='pending_payment' AND o.admin_deleted_at IS NULL;
    RETURN jsonb_build_object('ok',false,'reason','already_has_access');
  END IF;
  IF nullif(btrim(v_summary.payment_provider),'') IS NULL OR nullif(btrim(v_summary.payment_wallet_number),'') IS NULL THEN
    RETURN jsonb_build_object('ok',false,'reason','payment_not_configured');
  END IF;
  UPDATE public.study_summary_orders SET status='expired',updated_at=now()
  WHERE student_id=v_student_id AND summary_id=p_summary_id AND status='pending_payment'
    AND expires_at IS NOT NULL AND expires_at<=now();
  SELECT * INTO v_order FROM public.study_summary_orders
  WHERE student_id=v_student_id AND summary_id=p_summary_id AND status='pending_payment'
    AND (expires_at IS NULL OR expires_at>now()) ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    INSERT INTO public.study_summary_orders(student_id,summary_id,amount,status,payment_method,payment_number,order_code,expires_at,access_hours)
    VALUES(v_student_id,p_summary_id,v_summary.price,'pending_payment',v_summary.payment_provider,v_summary.payment_wallet_number,
      'AND-SUM-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),now()+interval '24 hours',NULL)
    RETURNING * INTO v_order;
    INSERT INTO public.study_summary_activity(student_id,summary_id,order_id,event_type,metadata)
    VALUES(v_student_id,p_summary_id,v_order.id,'order_created',jsonb_build_object('amount',v_order.amount,'status',v_order.status,'order_code',v_order.order_code));
  END IF;
  RETURN jsonb_build_object('ok',true,'order',jsonb_build_object('id',v_order.id,
    'order_number',coalesce(v_order.order_code,upper(left(replace(v_order.id::text,'-',''),12))),
    'order_code',v_order.order_code,'summary_id',v_order.summary_id,'amount',v_order.amount,'status',v_order.status,
    'created_at',v_order.created_at,'expires_at',v_order.expires_at,'payment_provider',v_summary.payment_provider,
    'payment_wallet_number',v_summary.payment_wallet_number));
END;
$$;


ALTER FUNCTION "public"."student_create_paid_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Keep the legacy RPC name compatible, but route it through the same
  -- access checks and idempotent order logic as the current payment flow.
  RETURN public.student_create_paid_study_summary_order(p_session_token, p_summary_id);
END;
$$;


ALTER FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid", "p_access_hours" integer DEFAULT 24) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- All legacy callers use the same verified session, entitlement, availability,
  -- payment configuration, and idempotent-order checks as the current flow.
  -- Keep the legacy parameter for API compatibility; the current product price
  -- and validity are controlled by the published summary/package configuration.
  IF p_access_hours NOT IN (24, 48) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_package');
  END IF;
  RETURN public.student_create_paid_study_summary_order(p_session_token, p_summary_id);
END;
$$;


ALTER FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid", "p_access_hours" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_device_auth"("p_student_code" "text", "p_national_id" "text", "p_device_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_student public.students%rowtype;
  v_hash text;
  v_credential_hash text;
  v_bound_hash text;
  v_session_token uuid;
  v_failed_count integer := 0;
  v_device_failed_count integer := 0;
  v_reason text;
  v_is_resume boolean;
begin
  if coalesce(length(p_device_token), 0) < 40 or length(p_device_token) > 256 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_device');
  end if;
  v_hash := encode(extensions.digest(convert_to(p_device_token, 'UTF8'), 'sha256'), 'hex');
  v_is_resume := coalesce(btrim(p_student_code), '') = '' and coalesce(btrim(p_national_id), '') = '';
  delete from public.student_device_auth_attempts where attempted_at < now() - interval '1 day';
  v_credential_hash := encode(
    extensions.digest(convert_to(lower(btrim(coalesce(p_student_code, ''))), 'UTF8'), 'sha256'), 'hex');

  if not v_is_resume then
    select count(*)::integer into v_failed_count
    from public.student_device_auth_attempts
    where credential_hash = v_credential_hash
      and succeeded = false
      and attempted_at > now() - interval '15 minutes';
    select count(*)::integer into v_device_failed_count
    from public.student_device_auth_attempts
    where credential_hash = v_credential_hash
      and device_hash = v_hash
      and succeeded = false
      and attempted_at > now() - interval '15 minutes';
    if v_device_failed_count >= 5 or v_failed_count >= 20 then
      insert into public.student_device_auth_attempts(credential_hash, device_hash, succeeded, reason)
      values (v_credential_hash, v_hash, false, 'rate_limited');
      return jsonb_build_object('ok', false, 'reason', 'rate_limited');
    end if;
  end if;

  if v_is_resume then
    select s.* into v_student
    from public.student_device_bindings b
    join public.students s on s.id = b.student_id
    where b.device_token_hash = v_hash
      and s.deleted_at is null
      and coalesce(s.student_status, 'active') = 'active'
    limit 1;

    if not found then
      insert into public.student_device_auth_attempts(credential_hash, device_hash, succeeded, reason)
      values (v_credential_hash, v_hash, false, 'session_not_found');
      return jsonb_build_object('ok', false, 'reason', 'session_not_found');
    end if;
    update public.student_device_bindings set last_seen_at = now()
      where student_id = v_student.id and device_token_hash = v_hash;
  else
    if coalesce(btrim(p_student_code), '') = '' or coalesce(btrim(p_national_id), '') = '' then
      v_reason := 'invalid_credentials';
    else
      select * into v_student
      from public.students
      where deleted_at is null
        and coalesce(student_status, 'active') = 'active'
        and regexp_replace(public.normalize_student_login_digits(national_id), '[^0-9]', '', 'g') = regexp_replace(public.normalize_student_login_digits(p_national_id), '[^0-9]', '', 'g')
        and (
          lower(regexp_replace(public.normalize_student_login_digits(coalesce(enrollment_number, '')), '\s+', '', 'g')) = lower(regexp_replace(public.normalize_student_login_digits(p_student_code), '\s+', '', 'g'))
          or lower(regexp_replace(public.normalize_student_login_digits(id), '\s+', '', 'g')) = lower(regexp_replace(public.normalize_student_login_digits(p_student_code), '\s+', '', 'g'))
        )
      limit 1;

      if not found then
        v_reason := 'invalid_credentials';
      else
        perform pg_advisory_xact_lock(hashtext(v_student.id));
        select device_token_hash into v_bound_hash
        from public.student_device_bindings
        where student_id = v_student.id
        for update;

        if not found then
          insert into public.student_device_bindings(student_id, device_token_hash)
          values (v_student.id, v_hash)
          on conflict (student_id) do nothing;
          select device_token_hash into v_bound_hash
          from public.student_device_bindings where student_id = v_student.id;
        end if;

        if v_bound_hash is distinct from v_hash then
          v_reason := 'device_mismatch';
        else
          update public.student_device_bindings set last_seen_at = now()
          where student_id = v_student.id;
        end if;
      end if;
    end if;

    if v_reason is not null then
      insert into public.student_device_auth_attempts(credential_hash, device_hash, succeeded, reason)
      values (v_credential_hash, v_hash, false, v_reason);
      insert into public.student_portal_access_logs
        (student_id, enrollment_number, student_name, phone, competition_type, event_type, outcome, reason, provider, metadata)
      values
        (case when v_student.id is not null then v_student.id else null end,
         case when v_student.id is not null then coalesce(v_student.enrollment_number, v_student.id) else null end,
         case when v_student.id is not null then v_student.name else null end,
         case when v_student.id is not null then v_student.phone else null end,
         'student_portal', 'device_login', 'failed', v_reason, 'device_binding',
         jsonb_build_object('mode', 'credentials'));
      return jsonb_build_object('ok', false, 'reason', v_reason);
    end if;
  end if;

  insert into public.student_device_auth_attempts(credential_hash, device_hash, succeeded, reason)
  values (v_credential_hash, v_hash, true, case when v_is_resume then 'session_resume' else 'credentials' end);

  insert into public.competition_face_verified_sessions
    (student_id, competition_type, competition_id, expires_at, verification_method)
  values (v_student.id, 'student_portal', null, now() + interval '12 hours', 'device')
  returning token into v_session_token;

  insert into public.student_portal_access_logs
    (student_id, enrollment_number, student_name, phone, competition_type, event_type, outcome, reason, provider, metadata)
  values
    (v_student.id, coalesce(v_student.enrollment_number, v_student.id), v_student.name, v_student.phone,
     'student_portal', 'device_login', 'success',
     case when v_is_resume then 'session_resume' else 'credentials' end,
     'device_binding', jsonb_build_object('verification_method', 'device'));

  return jsonb_build_object(
    'ok', true,
    'token', v_session_token,
    'student', jsonb_build_object(
      'id', v_student.id, 'name', v_student.name, 'phone', coalesce(v_student.phone, ''),
      'branch', v_student.branch, 'program_id', v_student.program_id,
      'program', v_student.program, 'system_name', v_student.system_name,
      'photo_url', v_student.photo_url, 'date', v_student.date,
      'enrollment_number', coalesce(v_student.enrollment_number, v_student.id)
    )
  );
end;
$$;


ALTER FUNCTION "public"."student_device_auth"("p_student_code" "text", "p_national_id" "text", "p_device_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_student public.students%rowtype;
  v_device_hash text;
  v_bound_hash text;
  v_token uuid;
begin
  if coalesce(length(p_device_token), 0) < 40 or length(p_device_token) > 256 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_device');
  end if;
  if p_context_type not in ('exam_portal', 'weekly_quiz', 'public_competition')
     or (p_context_type = 'public_competition' and p_context_id is null)
     or (p_context_type <> 'public_competition' and p_context_id is not null) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_context');
  end if;

  v_device_hash := encode(extensions.digest(convert_to(p_device_token, 'UTF8'), 'sha256'), 'hex');
  select s.* into v_student
  from public.students s
  join public.student_device_bindings b on b.student_id = s.id
  where s.id = p_student_id
    and s.deleted_at is null
    and coalesce(s.student_status, 'active') = 'active'
    and b.device_token_hash = v_device_hash
  limit 1;

  if not found then
    select device_token_hash into v_bound_hash
    from public.student_device_bindings where student_id = p_student_id;
    if found and v_bound_hash is distinct from v_device_hash then
      return jsonb_build_object('ok', false, 'reason', 'device_mismatch');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'student_inactive');
  end if;

  update public.student_device_bindings
  set last_seen_at = now()
  where student_id = v_student.id and device_token_hash = v_device_hash;

  insert into public.competition_face_verified_sessions
    (student_id, competition_type, competition_id, expires_at, verification_method)
  values
    (v_student.id, p_context_type, p_context_id, now() + interval '2 hours', 'device')
  returning token into v_token;

  insert into public.student_portal_access_logs
    (student_id, enrollment_number, student_name, phone, competition_type, event_type, outcome, reason, provider, metadata)
  values
    (v_student.id, coalesce(v_student.enrollment_number, v_student.id), v_student.name, v_student.phone,
     p_context_type, 'device_context_session', 'success', 'device_binding', 'device_binding',
     jsonb_build_object('verification_method', 'device', 'competition_id', p_context_id));

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_in_seconds', 7200,
    'context_type', p_context_type, 'context_id', p_context_id);
end;
$$;


ALTER FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid", "p_passkey_session_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_student public.students%rowtype;
  v_device_hash text;
  v_bound_hash text;
  v_token uuid;
  v_passkey_ok boolean := false;
begin
  if coalesce(length(p_device_token), 0) < 40 or length(p_device_token) > 256 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_device');
  end if;
  if p_context_type not in ('exam_portal', 'weekly_quiz', 'public_competition')
     or (p_context_type = 'public_competition' and p_context_id is null)
     or (p_context_type <> 'public_competition' and p_context_id is not null) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_context');
  end if;
  if p_passkey_session_token is null then
    return jsonb_build_object('ok', false, 'reason', 'passkey_required');
  end if;

  v_device_hash := encode(extensions.digest(convert_to(p_device_token, 'UTF8'), 'sha256'), 'hex');
  select s.* into v_student
  from public.students s
  join public.student_device_bindings b on b.student_id = s.id
  where s.id = p_student_id
    and s.deleted_at is null
    and coalesce(s.student_status, 'active') = 'active'
    and b.device_token_hash = v_device_hash
  limit 1;

  if not found then
    select device_token_hash into v_bound_hash
    from public.student_device_bindings where student_id = p_student_id;
    if found and v_bound_hash is distinct from v_device_hash then
      return jsonb_build_object('ok', false, 'reason', 'device_mismatch');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'student_inactive');
  end if;

  select exists(
    select 1 from public.student_passkey_sessions ps
    where ps.token = p_passkey_session_token
      and ps.student_id = v_student.id
      and ps.device_token_hash = v_device_hash
      and ps.expires_at > now()
  ) into v_passkey_ok;
  if not v_passkey_ok then
    return jsonb_build_object('ok', false, 'reason', 'passkey_required');
  end if;

  update public.student_device_bindings set last_seen_at = now()
  where student_id = v_student.id and device_token_hash = v_device_hash;

  insert into public.competition_face_verified_sessions
    (student_id, competition_type, competition_id, expires_at, verification_method)
  values
    (v_student.id, p_context_type, p_context_id, now() + interval '2 hours', 'device_passkey')
  returning token into v_token;

  insert into public.student_portal_access_logs
    (student_id, enrollment_number, student_name, phone, competition_type, event_type, outcome, reason, provider, metadata)
  values
    (v_student.id, coalesce(v_student.enrollment_number, v_student.id), v_student.name, v_student.phone,
     p_context_type, 'device_context_session', 'success', 'device_passkey', 'device_passkey',
     jsonb_build_object('verification_method', 'device_passkey', 'competition_id', p_context_id));

  return jsonb_build_object('ok', true, 'token', v_token, 'expires_in_seconds', 7200,
    'context_type', p_context_type, 'context_id', p_context_id, 'verification_method', 'device_passkey');
end;
$$;


ALTER FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid", "p_passkey_session_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_exam_list"("p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE st public.students%rowtype; result_data jsonb;
BEGIN
  SELECT * INTO st FROM public.students s
  WHERE s.id=btrim(coalesce(p_student_id,'')) AND s.deleted_at IS NULL AND coalesce(s.student_status,'active')='active'
    AND public.student_face_phone_matches(p_student_id,p_phone)
    AND EXISTS (SELECT 1 FROM public.competition_face_verified_sessions fs
      WHERE fs.token=p_face_token AND fs.student_id=s.id AND fs.competition_type='exam_portal' AND fs.expires_at>now())
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','verification_required'); END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id',e.id,'title',e.title,'subject_id',e.subject_id,'subject_name',sub.name,
      'program_id',e.program_id,'system_name',e.system_name,'branch',e.branch,'round',e.round,
      'duration_minutes',e.duration_minutes,'available_from',e.available_from,'available_until',e.available_until,
      'is_easy_retake',e.is_easy_retake,'total_score',e.total_score,
      'show_answers_after_submit',e.show_answers_after_submit,'is_placement_test',e.is_placement_test,
      'program_combos',e.program_combos,'attempt_status',at.status,'attempt_id',at.id,
      'round2_eligible',true
    ) ORDER BY e.available_from
  ),'[]'::jsonb)
  INTO result_data
  FROM public.exams e
  LEFT JOIN public.subjects sub ON sub.id::text=e.subject_id::text
  LEFT JOIN LATERAL (
    SELECT a.id,a.status FROM public.exam_attempts a
    WHERE a.exam_id=e.id AND a.student_id=st.id
    ORDER BY a.started_at DESC LIMIT 1
  ) at ON true
  WHERE e.branch=st.branch AND e.available_from<=now() AND e.available_until>now()
    AND (
      (jsonb_typeof(e.program_combos)='array' AND jsonb_array_length(e.program_combos)>0
       AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(e.program_combos) c(value)
         WHERE split_part(c.value,'|',1)=coalesce(st.program_id::text,'')
           AND (split_part(c.value,'|',2)='' OR split_part(c.value,'|',2)=coalesce(st.system_name,''))))
      OR
      (coalesce(jsonb_array_length(e.program_combos),0)=0
       AND (e.program_id IS NULL OR e.program_id::text=st.program_id::text)
       AND (e.system_name IS NULL OR e.system_name=st.system_name))
    )
    AND (
      coalesce(e.round,1)<>2 OR coalesce(e.is_placement_test,false)=true
      OR EXISTS (SELECT 1 FROM public.grades g
        WHERE g.student_id=st.id AND g.subject_id::text=e.subject_id::text AND g.grade_1 IS NOT NULL
          AND g.grade_1 < coalesce(sub.pass_grade_1,sub.min_pass,25))
    );
  RETURN jsonb_build_object('ok',true,'exams',result_data);
END;
$$;


ALTER FUNCTION "public"."student_exam_list"("p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_exam_resume_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE st public.students%rowtype; ex public.exams%rowtype; att public.exam_attempts%rowtype; qs jsonb; sub public.subjects%rowtype;
BEGIN
  SELECT * INTO st FROM public.students s
  WHERE s.id=btrim(coalesce(p_student_id,'')) AND s.deleted_at IS NULL AND coalesce(s.student_status,'active')='active'
    AND public.student_face_phone_matches(p_student_id,p_phone)
    AND EXISTS (SELECT 1 FROM public.competition_face_verified_sessions fs WHERE fs.token=p_face_token AND fs.student_id=s.id AND fs.competition_type='exam_portal' AND fs.expires_at>now())
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','verification_required'); END IF;
  SELECT * INTO ex FROM public.exams WHERE id=p_exam_id LIMIT 1;
  SELECT * INTO att FROM public.exam_attempts WHERE exam_id=p_exam_id AND student_id=st.id ORDER BY started_at DESC LIMIT 1;
  IF ex.id IS NULL OR att.id IS NULL OR ex.branch IS DISTINCT FROM st.branch THEN
    RETURN jsonb_build_object('ok',false,'reason','attempt_not_found');
  END IF;
  IF jsonb_typeof(ex.program_combos)='array' AND jsonb_array_length(ex.program_combos)>0 THEN
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(ex.program_combos) c(value)
      WHERE split_part(c.value,'|',1)=coalesce(st.program_id::text,'')
      AND (split_part(c.value,'|',2)='' OR split_part(c.value,'|',2)=coalesce(st.system_name,''))) THEN
      RETURN jsonb_build_object('ok',false,'reason','program_not_allowed');
    END IF;
  ELSIF (ex.program_id IS NOT NULL AND ex.program_id::text<>st.program_id::text)
     OR (ex.system_name IS NOT NULL AND ex.system_name<>st.system_name) THEN
    RETURN jsonb_build_object('ok',false,'reason','program_not_allowed');
  END IF;
  SELECT * INTO sub FROM public.subjects WHERE id::text=ex.subject_id::text LIMIT 1;
  IF coalesce(ex.round,1)=2 AND NOT coalesce(ex.is_placement_test,false) AND NOT EXISTS (
    SELECT 1 FROM public.grades g WHERE g.student_id=st.id AND g.subject_id::text=ex.subject_id::text
      AND g.grade_1 IS NOT NULL AND g.grade_1 < coalesce(sub.pass_grade_1,sub.min_pass,25)
  ) THEN RETURN jsonb_build_object('ok',false,'reason','round2_not_eligible'); END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'question_text',q.question_text,'question_type',q.question_type,
    'option_a',q.option_a,'option_b',q.option_b,'option_c',q.option_c,'option_d',q.option_d,
    'points',q.points,'order_num',q.order_num
  ) ORDER BY ord.n),'[]'::jsonb) INTO qs
  FROM jsonb_array_elements_text(att.question_order) WITH ORDINALITY ord(id,n)
  JOIN public.exam_questions q ON q.id::text=ord.id;
  RETURN jsonb_build_object('ok',true,'exam',to_jsonb(ex)||jsonb_build_object('subject_name',sub.name),
    'attempt',to_jsonb(att),'questions',qs);
END;
$$;


ALTER FUNCTION "public"."student_exam_resume_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_exam_save_answers"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE att public.exam_attempts%rowtype; kv record; q public.exam_questions%rowtype;
BEGIN
  IF NOT public.student_face_phone_matches(p_student_id,p_phone)
    OR NOT EXISTS (SELECT 1 FROM public.competition_face_verified_sessions fs WHERE fs.token=p_face_token
      AND fs.student_id=btrim(p_student_id) AND fs.competition_type='exam_portal' AND fs.expires_at>now()) THEN
    RETURN jsonb_build_object('ok',false,'reason','verification_required');
  END IF;
  SELECT * INTO att FROM public.exam_attempts WHERE id=p_attempt_id AND student_id=btrim(p_student_id) AND status='in_progress' LIMIT 1;
  IF NOT FOUND OR jsonb_typeof(coalesce(p_answers,'{}'::jsonb))<>'object' THEN
    RETURN jsonb_build_object('ok',false,'reason','attempt_not_found');
  END IF;
  FOR kv IN SELECT key,value FROM jsonb_each(coalesce(p_answers,'{}'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(att.question_order) ids(id) WHERE ids.id=kv.key) THEN
      RETURN jsonb_build_object('ok',false,'reason','question_not_in_attempt');
    END IF;
    SELECT * INTO q FROM public.exam_questions WHERE id::text=kv.key AND exam_id=att.exam_id LIMIT 1;
    IF NOT FOUND OR (q.question_type='truefalse' AND kv.value #>> '{}' NOT IN ('true','false'))
      OR (coalesce(q.question_type,'')<>'truefalse' AND kv.value #>> '{}' NOT IN ('a','b','c','d')) THEN
      RETURN jsonb_build_object('ok',false,'reason','invalid_answer');
    END IF;
  END LOOP;
  UPDATE public.exam_attempts SET answers=coalesce(p_answers,'{}'::jsonb) WHERE id=att.id;
  RETURN jsonb_build_object('ok',true);
END;
$$;


ALTER FUNCTION "public"."student_exam_save_answers"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_exam_start_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE st public.students%rowtype; ex public.exams%rowtype; v_order jsonb; att public.exam_attempts%rowtype; qs jsonb; v_subject public.subjects%rowtype;
BEGIN
  SELECT * INTO st FROM public.students s
  WHERE s.id=btrim(coalesce(p_student_id,'')) AND s.deleted_at IS NULL AND coalesce(s.student_status,'active')='active'
    AND public.student_face_phone_matches(p_student_id,p_phone)
    AND EXISTS (SELECT 1 FROM public.competition_face_verified_sessions fs WHERE fs.token=p_face_token AND fs.student_id=s.id AND fs.competition_type='exam_portal' AND fs.expires_at>now())
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','verification_required'); END IF;
  SELECT * INTO ex FROM public.exams e WHERE e.id=p_exam_id LIMIT 1;
  IF NOT FOUND OR ex.branch IS DISTINCT FROM st.branch OR ex.available_from>now() OR ex.available_until<=now() THEN
    RETURN jsonb_build_object('ok',false,'reason','exam_unavailable');
  END IF;
  IF jsonb_typeof(ex.program_combos)='array' AND jsonb_array_length(ex.program_combos)>0 THEN
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(ex.program_combos) c(value)
      WHERE split_part(c.value,'|',1)=coalesce(st.program_id::text,'')
      AND (split_part(c.value,'|',2)='' OR split_part(c.value,'|',2)=coalesce(st.system_name,''))) THEN
      RETURN jsonb_build_object('ok',false,'reason','program_not_allowed');
    END IF;
  ELSIF (ex.program_id IS NOT NULL AND ex.program_id::text<>st.program_id::text)
     OR (ex.system_name IS NOT NULL AND ex.system_name<>st.system_name) THEN
    RETURN jsonb_build_object('ok',false,'reason','program_not_allowed');
  END IF;
  SELECT * INTO v_subject FROM public.subjects WHERE id::text=ex.subject_id::text LIMIT 1;
  IF coalesce(ex.round,1)=2 AND NOT coalesce(ex.is_placement_test,false) THEN
    IF NOT EXISTS (SELECT 1 FROM public.grades g WHERE g.student_id=st.id AND g.subject_id::text=ex.subject_id::text
      AND g.grade_1 IS NOT NULL AND g.grade_1 < coalesce(v_subject.pass_grade_1,v_subject.min_pass,25)) THEN
      RETURN jsonb_build_object('ok',false,'reason','round2_not_eligible');
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exam_attempts a WHERE a.exam_id=ex.id AND a.student_id=st.id) THEN
    RETURN jsonb_build_object('ok',false,'reason','attempt_exists');
  END IF;
  SELECT jsonb_agg(q.id ORDER BY random()) INTO v_order FROM public.exam_questions q WHERE q.exam_id=ex.id;
  IF coalesce(jsonb_array_length(v_order),0)=0 THEN RETURN jsonb_build_object('ok',false,'reason','no_questions'); END IF;
  INSERT INTO public.exam_attempts(exam_id,student_id,question_order,started_at,status,max_score)
  VALUES(ex.id,st.id,v_order,now(),'in_progress',coalesce(ex.total_score,100))
  RETURNING * INTO att;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'question_text',q.question_text,'question_type',q.question_type,
    'option_a',q.option_a,'option_b',q.option_b,'option_c',q.option_c,'option_d',q.option_d,
    'points',q.points,'order_num',q.order_num
  ) ORDER BY ord.n),'[]'::jsonb) INTO qs
  FROM jsonb_array_elements_text(att.question_order) WITH ORDINALITY ord(id,n)
  JOIN public.exam_questions q ON q.id::text=ord.id;
  RETURN jsonb_build_object('ok',true,'exam',to_jsonb(ex)||jsonb_build_object('subject_name',v_subject.name),
    'attempt',to_jsonb(att),'questions',qs);
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok',false,'reason','attempt_exists');
END;
$$;


ALTER FUNCTION "public"."student_exam_start_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_exam_submit_attempt"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb", "p_cheating" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  att public.exam_attempts%rowtype;
  ex public.exams%rowtype;
  q public.exam_questions%rowtype;
  kv record;
  v_answers jsonb:=coalesce(p_answers,'{}'::jsonb);
  raw_score numeric:=0;
  raw_max numeric:=0;
  v_final_score numeric:=0;
  v_max_score numeric:=100;
  v_now timestamptz:=now();
  v_end timestamptz;
  v_time integer:=0;
  v_correct_data jsonb:='[]'::jsonb;
  v_subject public.subjects%rowtype;
  v_existing public.grades%rowtype;
  v_pass numeric;
BEGIN
  IF NOT public.student_face_phone_matches(p_student_id,p_phone)
    OR NOT EXISTS (SELECT 1 FROM public.competition_face_verified_sessions fs
      WHERE fs.token=p_face_token AND fs.student_id=btrim(p_student_id)
        AND fs.competition_type='exam_portal' AND fs.expires_at>now()) THEN
    RETURN jsonb_build_object('ok',false,'reason','verification_required');
  END IF;
  SELECT * INTO att FROM public.exam_attempts
    WHERE id=p_attempt_id AND student_id=btrim(p_student_id) AND status='in_progress' LIMIT 1;
  IF NOT FOUND OR jsonb_typeof(v_answers)<>'object' THEN
    RETURN jsonb_build_object('ok',false,'reason','attempt_not_found');
  END IF;
  SELECT * INTO ex FROM public.exams WHERE id=att.exam_id LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','exam_not_found'); END IF;
  IF v_now < att.started_at THEN RETURN jsonb_build_object('ok',false,'reason','invalid_start_time'); END IF;
  v_end:=least(
    att.started_at+make_interval(mins=>greatest(1,coalesce(ex.duration_minutes,1))),
    coalesce(ex.available_until,att.started_at+make_interval(mins=>greatest(1,coalesce(ex.duration_minutes,1))))
  );
  v_time:=greatest(0,floor(extract(epoch from (least(v_now,v_end)-att.started_at)))::integer);
  v_max_score:=coalesce(ex.total_score,100); IF v_now > v_end THEN v_answers:=coalesce(att.answers,'{}'::jsonb); END IF;

  FOR kv IN SELECT key,value FROM jsonb_each(v_answers) LOOP
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(att.question_order) ids(id) WHERE ids.id=kv.key) THEN
      RETURN jsonb_build_object('ok',false,'reason','question_not_in_attempt');
    END IF;
    SELECT * INTO q FROM public.exam_questions WHERE id::text=kv.key AND exam_id=ex.id LIMIT 1;
    IF NOT FOUND OR (q.question_type='truefalse' AND kv.value #>> '{}' NOT IN ('true','false'))
      OR (coalesce(q.question_type,'')<>'truefalse' AND kv.value #>> '{}' NOT IN ('a','b','c','d')) THEN
      RETURN jsonb_build_object('ok',false,'reason','invalid_answer');
    END IF;
  END LOOP;

  IF NOT coalesce(p_cheating,false) THEN
    FOR q IN
      SELECT eq.* FROM public.exam_questions eq
      WHERE eq.exam_id=ex.id AND eq.id::text IN (SELECT jsonb_array_elements_text(att.question_order))
    LOOP
      raw_max:=raw_max+coalesce(q.points,1);
      IF v_answers->>q.id::text=q.correct_answer THEN raw_score:=raw_score+coalesce(q.points,1); END IF;
      IF coalesce(ex.show_answers_after_submit,false) THEN
        v_correct_data:=v_correct_data||jsonb_build_array(jsonb_build_object(
          'id',q.id,'question_text',q.question_text,'question_type',q.question_type,
          'option_a',q.option_a,'option_b',q.option_b,'option_c',q.option_c,'option_d',q.option_d,
          'correct_answer',q.correct_answer,'points',q.points
        ));
      END IF;
    END LOOP;
    v_final_score:=CASE WHEN raw_max>0 THEN round((raw_score/raw_max)*v_max_score,2) ELSE 0 END;
  ELSE
    v_final_score:=0;
    v_correct_data:='[]'::jsonb;
  END IF;

  UPDATE public.exam_attempts SET answers=v_answers,score=v_final_score,max_score=v_max_score,
    submitted_at=v_now,status='submitted',flagged_cheating=coalesce(p_cheating,false),time_taken_seconds=v_time
  WHERE id=att.id;

  IF NOT coalesce(ex.is_placement_test,false) THEN
    SELECT * INTO v_subject FROM public.subjects WHERE id::text=ex.subject_id::text LIMIT 1;
    IF coalesce(ex.round,1)=2 THEN
      SELECT * INTO v_existing FROM public.grades WHERE student_id=att.student_id AND subject_id::text=ex.subject_id::text LIMIT 1;
      v_pass:=coalesce(v_subject.pass_grade_1,v_subject.min_pass,25);
      IF v_existing.id IS NOT NULL AND v_existing.grade_1 IS NOT NULL AND v_existing.grade_1<v_pass THEN
        UPDATE public.grades SET grade_2=v_final_score,grade_2_source='electronic',
          grade_2_note=CASE WHEN coalesce(p_cheating,false) THEN 'غشاش' ELSE NULL END,updated_at=now()
        WHERE id=v_existing.id;
      END IF;
    ELSE
      INSERT INTO public.grades(student_id,subject_id,grade_1,grade_1_source,grade_1_note,updated_at)
      VALUES(att.student_id,ex.subject_id,v_final_score,'electronic',
        CASE WHEN coalesce(p_cheating,false) THEN 'غشاش' ELSE NULL END,now())
      ON CONFLICT(student_id,subject_id) DO UPDATE SET grade_1=EXCLUDED.grade_1,
        grade_1_source='electronic',grade_1_note=EXCLUDED.grade_1_note,updated_at=now();
    END IF;
  END IF;
  RETURN jsonb_build_object('ok',true,'score',v_final_score,'max_score',v_max_score,
    'flagged_cheating',coalesce(p_cheating,false),'time_taken_seconds',v_time,
    'answers',v_answers,'correct_data',v_correct_data,'submitted_at',v_now);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'student_exam_submit_attempt failed: %',SQLERRM;
  RETURN jsonb_build_object('ok',false,'reason','submit_failed');
END;
$$;


ALTER FUNCTION "public"."student_exam_submit_attempt"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb", "p_cheating" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" double precision, "p_face_threshold" double precision, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.student_face_audit_finalize(
    p_student_id,
    p_outcome,
    p_failure_code,
    p_failure_reason,
    p_face_distance::numeric,
    p_face_threshold::numeric,
    p_reference_photo_url,
    p_verification_method,
    p_session_token,
    coalesce(p_metadata, '{}'::jsonb)
  );
$$;


ALTER FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" double precision, "p_face_threshold" double precision, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" numeric, "p_face_threshold" numeric, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.weekly_quiz_access_audit a
  set outcome = p_outcome,
      failure_code = p_failure_code,
      failure_reason = p_failure_reason,
      face_distance = p_face_distance,
      face_threshold = p_face_threshold,
      reference_photo_url = p_reference_photo_url,
      verification_method = p_verification_method,
      session_token = p_session_token,
      metadata = coalesce(a.metadata,'{}'::jsonb) || coalesce(p_metadata,'{}'::jsonb)
  where a.id = (
    select x.id from public.weekly_quiz_access_audit x
    where x.student_id = p_student_id
      and x.outcome is null
      and x.entered_at >= now() - interval '15 minutes'
    order by x.entered_at desc
    limit 1
  );
end;
$$;


ALTER FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" numeric, "p_face_threshold" numeric, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_face_enroll"("p_student_id" "text", "p_phone" "text", "p_descriptor" "jsonb", "p_consent" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  st public.students%rowtype;
  v_phone_ok boolean;
  v_enrollment text;
begin
  select * into st
  from public.student_face_resolve(p_student_id)
  limit 1;

  if st.id is null then
    return jsonb_build_object('ok',false,'reason','student_not_found');
  end if;

  v_phone_ok := public.student_face_phone_matches(st.id, p_phone);
  if not v_phone_ok then
    return jsonb_build_object('ok',false,'reason','phone_mismatch');
  end if;

  if coalesce(p_consent,false) is not true then
    return jsonb_build_object('ok',false,'reason','consent_required');
  end if;

  if jsonb_typeof(p_descriptor) <> 'array' or jsonb_array_length(p_descriptor) <> 128 then
    return jsonb_build_object('ok',false,'reason','invalid_face_descriptor');
  end if;

  v_enrollment := coalesce(nullif(st.enrollment_number,''), st.id);

  /*
   * A reset deactivates the old row but intentionally keeps its history.
   * Re-enrollment must reactivate/update that unique student/provider row,
   * not INSERT a duplicate row.
   */
  insert into public.competition_face_enrollments
    (student_id,enrollment_number,provider,provider_subject_id,consent_at,consent_version,active,face_descriptor,model_version,updated_at)
  values
    (st.id,v_enrollment,'face-api.js',st.id,now(),'face-enrollment-v2',true,p_descriptor,'face-api.js-0.22.2',now())
  on conflict (student_id, provider) do update
    set enrollment_number = excluded.enrollment_number,
        provider_subject_id = excluded.provider_subject_id,
        consent_at = excluded.consent_at,
        consent_version = excluded.consent_version,
        active = true,
        face_descriptor = excluded.face_descriptor,
        model_version = excluded.model_version,
        updated_at = now();

  insert into public.competition_security_logs
    (competition_type,competition_id,enrollment_number,student_id,event_type,outcome,reason,metadata)
  values
    ('identity','face-enroll',v_enrollment,st.id,'face_enroll','success','face_enrolled',
     jsonb_build_object('provider','face-api.js','model_version','face-api.js-0.22.2'));

  return jsonb_build_object(
    'ok',true,
    'reason','face_enrolled',
    'student',jsonb_build_object('id',st.id,'name',st.name,'enrollment_number',st.enrollment_number)
  );
end;
$$;


ALTER FUNCTION "public"."student_face_enroll"("p_student_id" "text", "p_phone" "text", "p_descriptor" "jsonb", "p_consent" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_face_phone_matches"("p_student_id" "text", "p_phone" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ declare supplied text:=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g'); normalized text; st public.students%rowtype; begin normalized:=case when supplied like '0020%' then '0'||substr(supplied,5) when supplied like '20%' and length(supplied)=12 then '0'||substr(supplied,3) when supplied like '1%' and length(supplied)=10 then '0'||supplied else supplied end; if normalized='' then return false; end if; st:=public.student_face_resolve(p_student_id); if st.id is null then return false; end if; return exists(select 1 from (values(st.phone),(st.guardian_phone),(st.parent_phone)) v(raw_phone) where (case when regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g') like '0020%' then '0'||substr(regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g'),5) when regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g') like '20%' and length(regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g'))=12 then '0'||substr(regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g'),3) when regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g') like '1%' and length(regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g'))=10 then '0'||regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g') else regexp_replace(coalesce(v.raw_phone,''),'[^0-9]','','g') end)=normalized); end; $$;


ALTER FUNCTION "public"."student_face_phone_matches"("p_student_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."students" (
    "id" "text" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "age" "text",
    "edu" "text",
    "address" "text",
    "phone" "text",
    "guardian_name" "text",
    "guardian_phone" "text",
    "branch" "text",
    "program_id" "text",
    "program" "text",
    "system_name" "text",
    "date" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid",
    "photo_url" "text",
    "enrollment_number" "text",
    "enrollment_date" "date",
    "qualification" "text",
    "parent_name" "text",
    "parent_phone" "text",
    "national_id" "text",
    "total_due" numeric DEFAULT 0,
    "job" "text",
    "deleted_at" timestamp with time zone,
    "deleted_by" "uuid",
    "referred_by" "text",
    "referral_reward_given" boolean DEFAULT false,
    "blood_type" "text",
    "birth_date" "date",
    "student_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "dismissed_at" timestamp with time zone,
    "dismissed_by" "uuid"
);


ALTER TABLE "public"."students" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_face_resolve"("p_student_ref" "text") RETURNS "public"."students"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ declare st public.students%rowtype; ref text:=btrim(coalesce(p_student_ref,'')); begin if ref='' then return null; end if; select * into st from public.students where id=ref and deleted_at is null limit 1; if found then return st; end if; select * into st from public.students where enrollment_number=ref and deleted_at is null limit 1; if found then return st; end if; return null; end; $$;


ALTER FUNCTION "public"."student_face_resolve"("p_student_ref" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_face_status"("p_student_id" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ declare enrolled boolean; st public.students%rowtype; begin st:=public.student_face_resolve(p_student_id); if st.id is null or not public.student_face_phone_matches(st.id,p_phone) then return jsonb_build_object('verified',false,'enrolled',false,'reason',case when st.id is null then 'student_not_found' else 'phone_mismatch' end); end if; select coalesce(bool_or(active and face_descriptor is not null),false) into enrolled from public.competition_face_enrollments where student_id=st.id and provider in ('face-api.js','face-api-local'); return jsonb_build_object('verified',true,'enrolled',enrolled,'student',jsonb_build_object('id',st.id,'name',st.name,'enrollment_number',coalesce(st.enrollment_number,st.id),'photo_url',st.photo_url)); end; $$;


ALTER FUNCTION "public"."student_face_status"("p_student_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_face_verify"("p_student_id" "text", "p_phone" "text", "p_live_descriptor" "jsonb", "p_competition_type" "text" DEFAULT 'student_portal'::"text", "p_competition_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  st public.students%rowtype;
  ref_desc jsonb;
  ref_model text;
  ref_provider text;
  v_distance double precision;
  v_threshold double precision := 0.52;
  v_sum double precision := 0;
  v_count integer := 0;
  v_a double precision;
  v_b double precision;
  i integer;
  v_token uuid;
  v_enrollment text;
  v_reason text;
  v_failure text;
  v_type text := lower(coalesce(p_competition_type,'student_portal'));
begin
  select * into st from public.student_face_resolve(p_student_id) limit 1;
  if st.id is null then
    return jsonb_build_object('ok',false,'verified',false,'reason','student_not_found');
  end if;

  if not public.student_face_phone_matches(st.id,p_phone) then
    insert into public.student_portal_access_logs(student_id,enrollment_number,student_name,phone,competition_type,competition_id,event_type,outcome,reason,threshold,metadata)
    values(st.id,st.enrollment_number,st.name,p_phone,v_type,p_competition_id,'face_verify','failure','phone_mismatch',v_threshold,jsonb_build_object('stage','phone'));
    perform public.student_face_audit_finalize(st.id,'failure','phone_mismatch','رقم الهاتف غير مطابق للبيانات المسجلة',null,v_threshold,st.photo_url,'identity+face',null,jsonb_build_object('stage','phone'));
    return jsonb_build_object('ok',false,'verified',false,'reason','phone_mismatch','student',jsonb_build_object('id',st.id,'name',st.name,'enrollment_number',st.enrollment_number));
  end if;

  if jsonb_typeof(p_live_descriptor) <> 'array' or jsonb_array_length(p_live_descriptor) <> 128 then
    insert into public.student_portal_access_logs(student_id,enrollment_number,student_name,phone,competition_type,competition_id,event_type,outcome,reason,threshold,metadata)
    values(st.id,st.enrollment_number,st.name,p_phone,v_type,p_competition_id,'face_verify','failure','face_descriptor_invalid',v_threshold,jsonb_build_object('stage','descriptor'));
    perform public.student_face_audit_finalize(st.id,'failure','face_descriptor_invalid','تعذر قراءة بصمة الوجه من الصورة الحالية',null,v_threshold,st.photo_url,'face-api.js',null,jsonb_build_object('stage','descriptor'));
    return jsonb_build_object('ok',false,'verified',false,'reason','face_descriptor_invalid');
  end if;

  select e.face_descriptor,e.model_version,e.provider
    into ref_desc,ref_model,ref_provider
  from public.competition_face_enrollments e
  where e.student_id=st.id and e.active=true and e.provider in ('face-api.js','face-api-local')
  order by e.updated_at desc nulls last,e.created_at desc
  limit 1;

  if ref_desc is null then
    insert into public.student_portal_access_logs(student_id,enrollment_number,student_name,phone,competition_type,competition_id,event_type,outcome,reason,threshold,metadata)
    values(st.id,st.enrollment_number,st.name,p_phone,v_type,p_competition_id,'face_verify','failure','face_not_enrolled',v_threshold,jsonb_build_object('stage','reference'));
    perform public.student_face_audit_finalize(st.id,'failure','face_not_enrolled','لا توجد بصمة وجه مسجلة لهذا الطالب',null,v_threshold,st.photo_url,'face-api.js',null,jsonb_build_object('stage','reference'));
    return jsonb_build_object('ok',false,'verified',false,'reason','face_not_enrolled','reference_photo_url',st.photo_url);
  end if;

  if jsonb_typeof(ref_desc) <> 'array' or jsonb_array_length(ref_desc) <> 128 then
    insert into public.student_portal_access_logs(student_id,enrollment_number,student_name,phone,competition_type,competition_id,event_type,outcome,reason,threshold,metadata)
    values(st.id,st.enrollment_number,st.name,p_phone,v_type,p_competition_id,'face_verify','failure','reference_descriptor_invalid',v_threshold,jsonb_build_object('stage','reference','model_version',ref_model));
    perform public.student_face_audit_finalize(st.id,'failure','reference_descriptor_invalid','بصمة الوجه المرجعية غير صالحة وتحتاج إعادة تسجيل',null,v_threshold,st.photo_url,coalesce(ref_provider,'face-api.js'),null,jsonb_build_object('stage','reference','model_version',ref_model));
    return jsonb_build_object('ok',false,'verified',false,'reason','reference_descriptor_invalid');
  end if;

  for i in 0..127 loop
    v_a := (p_live_descriptor->>i)::double precision;
    v_b := (ref_desc->>i)::double precision;
    v_sum := v_sum + power(v_a-v_b,2);
    v_count := v_count + 1;
  end loop;
  v_distance := sqrt(v_sum);

  if v_distance <= v_threshold then
    if v_type in ('exam_portal','weekly_quiz','public_competition','student_portal') then
      v_token := gen_random_uuid();
      insert into public.competition_face_verified_sessions(token,student_id,competition_type,competition_id,created_at,expires_at)
      values(v_token,st.id,p_competition_type,p_competition_id,now(),now()+interval '30 minutes');
    end if;

    v_enrollment := coalesce(nullif(st.enrollment_number,''),st.id);
    insert into public.competition_security_logs
      (competition_type,competition_id,enrollment_number,student_id,event_type,outcome,reason,metadata)
    values(p_competition_type,p_competition_id,v_enrollment,st.id,'face_verify','success','face_match',jsonb_build_object('distance',v_distance,'threshold',v_threshold,'model_version',ref_model,'provider',ref_provider));

    insert into public.student_portal_access_logs(student_id,enrollment_number,student_name,phone,competition_type,competition_id,event_type,outcome,reason,distance,threshold,model_version,provider,metadata)
    values(st.id,v_enrollment,st.name,p_phone,v_type,p_competition_id,'face_verify','success','face_match',v_distance,v_threshold,ref_model,ref_provider,jsonb_build_object('session_token',v_token));

    perform public.student_face_audit_finalize(st.id,'success',null,'تم التحقق من الهوية بنجاح',v_distance,v_threshold,st.photo_url,coalesce(ref_provider,'face-api.js'),v_token,jsonb_build_object('model_version',ref_model,'provider',ref_provider));
    return jsonb_build_object('ok',true,'verified',true,'reason','face_match','distance',v_distance,'threshold',v_threshold,'session_token',v_token,'token',v_token,'student',jsonb_build_object('id',st.id,'name',st.name,'enrollment_number',st.enrollment_number,'photo_url',st.photo_url));
  end if;

  v_reason := 'الصورة الحالية لا تتطابق بما يكفي مع الصورة المرجعية المسجلة';
  v_failure := 'face_mismatch';
  v_enrollment := coalesce(nullif(st.enrollment_number,''),st.id);
  insert into public.competition_security_logs
    (competition_type,competition_id,enrollment_number,student_id,event_type,outcome,reason,metadata)
  values(p_competition_type,p_competition_id,v_enrollment,st.id,'face_verify','failure',v_failure,jsonb_build_object('distance',v_distance,'threshold',v_threshold,'model_version',ref_model,'provider',ref_provider));

  insert into public.student_portal_access_logs(student_id,enrollment_number,student_name,phone,competition_type,competition_id,event_type,outcome,reason,distance,threshold,model_version,provider,metadata)
  values(st.id,v_enrollment,st.name,p_phone,v_type,p_competition_id,'face_verify','failure',v_failure,v_distance,v_threshold,ref_model,ref_provider,jsonb_build_object('stage','match'));

  perform public.student_face_audit_finalize(st.id,'failure',v_failure,v_reason,v_distance,v_threshold,st.photo_url,coalesce(ref_provider,'face-api.js'),null,jsonb_build_object('model_version',ref_model,'provider',ref_provider));
  return jsonb_build_object('ok',false,'verified',false,'reason',v_failure,'message',v_reason,'distance',v_distance,'threshold',v_threshold,'reference_photo_url',st.photo_url,'student',jsonb_build_object('id',st.id,'name',st.name,'enrollment_number',st.enrollment_number));
end;
$$;


ALTER FUNCTION "public"."student_face_verify"("p_student_id" "text", "p_phone" "text", "p_live_descriptor" "jsonb", "p_competition_type" "text", "p_competition_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_get_study_summary_question"("p_session_token" "uuid", "p_summary_id" "uuid", "p_question_number" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_student_id text;
  v_summary public.study_summaries%rowtype;
  v_question jsonb;
  v_total integer;
  v_package_id uuid;
  v_package_name text;
  v_representative_id uuid;
BEGIN
  SELECT s.student_id INTO v_student_id
  FROM public.competition_face_verified_sessions s
  JOIN public.students st ON st.id=s.student_id
  WHERE s.token=p_session_token AND s.competition_type='student_portal'
    AND s.expires_at>now() AND st.deleted_at IS NULL
    AND coalesce(st.student_status,'active')='active'
  LIMIT 1;

  IF v_student_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'reason','session_expired');
  END IF;

  SELECT * INTO v_summary
  FROM public.study_summaries sm
  WHERE sm.id=p_summary_id AND sm.is_published=true AND sm.is_approved=true
    AND (sm.available_from IS NULL OR sm.available_from<=now())
    AND ((sm.available_until IS NULL OR sm.available_until>now()) OR EXISTS (
      SELECT 1 FROM public.study_summary_entitlements e
      WHERE e.student_id=v_student_id AND e.summary_id=sm.id AND e.revoked_at IS NULL
        AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
    ))
    AND (coalesce(sm.target_all,true) OR EXISTS (
      SELECT 1 FROM public.students st WHERE st.id=v_student_id
        AND (nullif(btrim(sm.target_branch),'') IS NOT NULL OR nullif(btrim(sm.target_system),'') IS NOT NULL OR nullif(btrim(sm.target_batch),'') IS NOT NULL)
        AND public.study_summary_target_matches(sm.target_branch,st.branch)
        AND public.study_summary_target_matches(sm.target_system,st.system_name)
        AND public.study_summary_target_matches(sm.target_batch,st.program)
    ));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',false,'reason','summary_unavailable');
  END IF;

  SELECT pi.package_id,p.name INTO v_package_id,v_package_name
  FROM public.study_summary_package_items pi
  JOIN public.study_summary_packages p ON p.id=pi.package_id AND p.is_active=true
  WHERE pi.summary_id=p_summary_id
  LIMIT 1;

  IF v_package_id IS NOT NULL THEN
    SELECT min(pi.summary_id::text)::uuid INTO v_representative_id
    FROM public.study_summary_package_items pi
    WHERE pi.package_id=v_package_id;
  END IF;

  IF (v_package_id IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.study_summary_entitlements e
    WHERE e.student_id=v_student_id AND e.summary_id=p_summary_id AND e.revoked_at IS NULL
      AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
  )) OR (v_package_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.study_summary_entitlements e
    WHERE e.student_id=v_student_id AND e.summary_id=v_representative_id AND e.revoked_at IS NULL
      AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
  )) THEN
    INSERT INTO public.study_summary_activity(student_id,summary_id,event_type,metadata)
    VALUES(v_student_id,p_summary_id,'access_denied',jsonb_build_object('reason','no_active_entitlement'));
    RETURN jsonb_build_object('ok',false,'reason','not_purchased');
  END IF;

  IF v_package_id IS NULL THEN
    SELECT count(*) INTO v_total
    FROM public.study_summary_questions q
    WHERE q.summary_id=p_summary_id AND q.is_selected=true AND q.is_approved=true
      AND q.batch_no IN (SELECT value::integer FROM jsonb_array_elements_text(coalesce(v_summary.enabled_batches,'[1,2]'::jsonb)))
      AND q.question_type IN (SELECT value FROM jsonb_array_elements_text(coalesce(v_summary.enabled_question_types,'["mcq","true_false","essay"]'::jsonb)));
  ELSE
    SELECT count(*) INTO v_total
    FROM public.study_summary_questions q
    JOIN public.study_summaries qsm ON qsm.id=q.summary_id
    WHERE q.summary_id IN (SELECT pi.summary_id FROM public.study_summary_package_items pi WHERE pi.package_id=v_package_id)
      AND q.is_selected=true AND q.is_approved=true
      AND q.batch_no IN (SELECT value::integer FROM jsonb_array_elements_text(coalesce(qsm.enabled_batches,'[1,2]'::jsonb)))
      AND q.question_type IN (SELECT value FROM jsonb_array_elements_text(coalesce(qsm.enabled_question_types,'["mcq","true_false","essay"]'::jsonb)));
  END IF;

  IF v_total=0 THEN RETURN jsonb_build_object('ok',false,'reason','empty_summary'); END IF;
  IF p_question_number<1 OR p_question_number>v_total THEN
    RETURN jsonb_build_object('ok',false,'reason','question_out_of_range','total',v_total);
  END IF;

  IF v_package_id IS NULL THEN
    SELECT jsonb_build_object('id',q.id,'question_text',q.question_text,'answer_text',q.answer_text,
      'explanation',q.explanation,'question_type',q.question_type,'options',q.options,'order_num',q.order_num)
    INTO v_question
    FROM public.study_summary_questions q
    WHERE q.summary_id=p_summary_id AND q.is_selected=true AND q.is_approved=true
      AND q.batch_no IN (SELECT value::integer FROM jsonb_array_elements_text(coalesce(v_summary.enabled_batches,'[1,2]'::jsonb)))
      AND q.question_type IN (SELECT value FROM jsonb_array_elements_text(coalesce(v_summary.enabled_question_types,'["mcq","true_false","essay"]'::jsonb)))
    ORDER BY q.batch_no,q.order_num,q.id OFFSET (p_question_number-1) LIMIT 1;
  ELSE
    SELECT jsonb_build_object('id',q.id,'question_text',q.question_text,'answer_text',q.answer_text,
      'explanation',q.explanation,'question_type',q.question_type,'options',q.options,'order_num',q.order_num)
    INTO v_question
    FROM public.study_summary_questions q
    JOIN public.study_summaries qsm ON qsm.id=q.summary_id
    WHERE q.summary_id IN (SELECT pi.summary_id FROM public.study_summary_package_items pi WHERE pi.package_id=v_package_id)
      AND q.is_selected=true AND q.is_approved=true
      AND q.batch_no IN (SELECT value::integer FROM jsonb_array_elements_text(coalesce(qsm.enabled_batches,'[1,2]'::jsonb)))
      AND q.question_type IN (SELECT value FROM jsonb_array_elements_text(coalesce(qsm.enabled_question_types,'["mcq","true_false","essay"]'::jsonb)))
    ORDER BY qsm.created_at,q.batch_no,q.order_num,q.id
    OFFSET (p_question_number-1) LIMIT 1;
  END IF;

  INSERT INTO public.study_summary_activity(student_id,summary_id,event_type,metadata)
  VALUES(v_student_id,p_summary_id,'question',jsonb_build_object('question_number',p_question_number,'package_id',v_package_id));

  RETURN jsonb_build_object('ok',true,
    'summary',jsonb_build_object('id',v_summary.id,'title',coalesce(v_package_name,v_summary.title),'subject_name',v_summary.subject_name),
    'question',v_question,'question_number',p_question_number,'total',v_total);
END;
$$;


ALTER FUNCTION "public"."student_get_study_summary_question"("p_session_token" "uuid", "p_summary_id" "uuid", "p_question_number" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_hide_completed_request"("p_student_id" "text", "p_phone" "text", "p_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  normalized_phone text := public.normalize_eg_phone(p_phone);
  student_row public.students%rowtype;
  request_row public.student_requests%rowtype;
BEGIN
  IF coalesce(btrim(p_student_id), '') = '' OR normalized_phone = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'identity_not_verified');
  END IF;

  SELECT st.* INTO student_row
  FROM public.students st
  WHERE st.id = btrim(p_student_id)
    AND st.deleted_at IS NULL
    AND public.normalize_eg_phone(st.phone) = normalized_phone
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'identity_not_verified');
  END IF;

  SELECT r.* INTO request_row
  FROM public.student_requests r
  WHERE r.id = p_request_id
    AND r.student_id = student_row.id
    AND r.requester_type = 'student'
    AND r.requester_phone = normalized_phone
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'request_not_found');
  END IF;

  IF request_row.status NOT IN ('resolved', 'closed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'request_not_completed');
  END IF;

  UPDATE public.student_requests
  SET student_hidden_at = coalesce(student_hidden_at, now())
  WHERE id = p_request_id;

  RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."student_hide_completed_request"("p_student_id" "text", "p_phone" "text", "p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_hide_study_summary_order"("p_session_token" "uuid", "p_order_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_student_id text;
BEGIN
 SELECT s.student_id INTO v_student_id FROM public.competition_face_verified_sessions s JOIN public.students st ON st.id=s.student_id
 WHERE s.token=p_session_token AND s.competition_type='student_portal' AND s.expires_at>now() AND st.deleted_at IS NULL
  AND coalesce(st.student_status,'active')='active' LIMIT 1;
 IF v_student_id IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','session_expired'); END IF;
 UPDATE public.study_summary_orders SET hidden_from_student=true,updated_at=now() WHERE id=p_order_id AND student_id=v_student_id;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','order_not_found'); END IF;
 RETURN jsonb_build_object('ok',true);
END;
$$;


ALTER FUNCTION "public"."student_hide_study_summary_order"("p_session_token" "uuid", "p_order_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_identity_check"("p_student_ref" "text", "p_national_id" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  st public.students%rowtype;
  v_nid text;
  v_phone_ok boolean;
  v_face_enrolled boolean;
  v_enrollment text;
begin
  select * into st from public.student_face_resolve(p_student_ref) limit 1;
  if st.id is null then
    return jsonb_build_object('ok',false,'reason','student_not_found');
  end if;

  v_nid := regexp_replace(coalesce(p_national_id,''),'[^0-9]','','g');
  if v_nid = '' or regexp_replace(coalesce(st.national_id,''),'[^0-9]','','g') <> v_nid then
    insert into public.competition_security_logs
      (competition_type,competition_id,enrollment_number,student_id,event_type,outcome,reason,metadata)
    values
      ('identity','precheck',coalesce(st.enrollment_number,st.id),st.id,'identity_check','failure','national_id_mismatch',jsonb_build_object('national_id_provided_last4',right(v_nid,4)));
    return jsonb_build_object('ok',false,'reason','national_id_mismatch');
  end if;

  v_phone_ok := public.student_face_phone_matches(st.id,p_phone);
  if not v_phone_ok then
    insert into public.competition_security_logs
      (competition_type,competition_id,enrollment_number,student_id,event_type,outcome,reason,metadata)
    values
      ('identity','precheck',coalesce(st.enrollment_number,st.id),st.id,'identity_check','failure','phone_mismatch',jsonb_build_object('phone_last4',right(regexp_replace(coalesce(p_phone,''),'[^0-9]','','g'),4)));
    return jsonb_build_object('ok',false,'reason','phone_mismatch');
  end if;

  select exists(
    select 1 from public.competition_face_enrollments e
    where e.student_id=st.id and e.active=true and e.provider in ('face-api.js','face-api-local')
  ) into v_face_enrolled;

  v_enrollment := coalesce(nullif(st.enrollment_number,''),st.id);
  insert into public.competition_security_logs
    (competition_type,competition_id,enrollment_number,student_id,event_type,outcome,reason,metadata)
  values
    ('identity','precheck',v_enrollment,st.id,'identity_check','success','identity_verified',jsonb_build_object('face_enrolled',v_face_enrolled));

  return jsonb_build_object(
    'ok',true,
    'reason','identity_verified',
    'face_enrolled',v_face_enrolled,
    'student',jsonb_build_object('id',st.id,'name',st.name,'enrollment_number',st.enrollment_number,'photo_url',st.photo_url)
  );
end;
$$;


ALTER FUNCTION "public"."student_identity_check"("p_student_ref" "text", "p_national_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_in_user_branch"("p_branch" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT public.get_user_branch() = 'الكل' OR p_branch = public.get_user_branch();
$$;


ALTER FUNCTION "public"."student_in_user_branch"("p_branch" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_list_study_summaries"("p_session_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_student_id text;
  v_result jsonb;
BEGIN
  SELECT s.student_id INTO v_student_id
  FROM public.competition_face_verified_sessions s
  JOIN public.students st ON st.id=s.student_id
  WHERE s.token=p_session_token
    AND s.competition_type='student_portal'
    AND s.expires_at>now()
    AND st.deleted_at IS NULL
    AND coalesce(st.student_status,'active')='active'
  LIMIT 1;

  IF v_student_id IS NULL THEN
    RETURN jsonb_build_object('ok',false,'reason','session_expired');
  END IF;

  UPDATE public.study_summary_orders
  SET status='expired',updated_at=now()
  WHERE student_id=v_student_id
    AND status='pending_payment'
    AND expires_at IS NOT NULL
    AND expires_at<=now();

  SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC),'[]'::jsonb)
  INTO v_result
  FROM (
    SELECT sm.created_at,
      jsonb_build_object(
        'id',coalesce(pkg.representative_id,sm.id),
        'title',coalesce(pkg.name,sm.title),
        'description',CASE WHEN pkg.package_id IS NOT NULL
          THEN 'الباقة الكاملة تشمل 3 أجزاء: صح وغلط 40 سؤال + اختياري 40 سؤال + مقالي 20 سؤال — السعر الإجمالي 40 ج.م.'
          ELSE sm.description END,
        'subject_name',sm.subject_name,
        'price',coalesce(pkg.price,sm.price),
        'validity_days',coalesce(pkg.validity_days,sm.validity_days),
        'question_count',CASE WHEN pkg.package_id IS NOT NULL THEN pkg.question_count ELSE (
          SELECT count(*) FROM public.study_summary_questions q
          WHERE q.summary_id=sm.id AND q.is_selected=true AND q.is_approved=true
            AND q.batch_no IN (SELECT value::integer FROM jsonb_array_elements_text(coalesce(sm.enabled_batches,'[1,2]'::jsonb)))
            AND q.question_type IN (SELECT value FROM jsonb_array_elements_text(coalesce(sm.enabled_question_types,'["mcq","true_false","essay"]'::jsonb)))
        ) END,
        'has_access',CASE WHEN pkg.package_id IS NOT NULL THEN pkg.has_representative_access ELSE EXISTS(
          SELECT 1 FROM public.study_summary_entitlements e
          WHERE e.student_id=v_student_id AND e.summary_id=sm.id AND e.revoked_at IS NULL
            AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
        ) END,
        'expires_at',CASE WHEN pkg.package_id IS NOT NULL THEN pkg.expires_at ELSE (
          SELECT max(e.expires_at) FROM public.study_summary_entitlements e
          WHERE e.student_id=v_student_id AND e.summary_id=sm.id AND e.revoked_at IS NULL
            AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
        ) END,
        'pending_order',EXISTS(
          SELECT 1 FROM public.study_summary_orders o
          WHERE o.student_id=v_student_id AND o.summary_id=coalesce(pkg.representative_id,sm.id)
            AND o.status='pending_payment' AND (o.expires_at IS NULL OR o.expires_at>now())
        )
      ) AS item
    FROM public.study_summaries sm
    JOIN public.students st ON st.id=v_student_id
    LEFT JOIN LATERAL (
      SELECT p.id AS package_id,p.name,p.price,p.validity_days,
        (SELECT min(pi0.summary_id::text)::uuid FROM public.study_summary_package_items pi0 WHERE pi0.package_id=p.id) AS representative_id,
        (SELECT count(*) FROM public.study_summary_questions q
          JOIN public.study_summaries qsm ON qsm.id=q.summary_id
          WHERE q.summary_id IN (SELECT pi2.summary_id FROM public.study_summary_package_items pi2 WHERE pi2.package_id=p.id)
            AND q.is_selected=true AND q.is_approved=true
            AND q.batch_no IN (SELECT value::integer FROM jsonb_array_elements_text(coalesce(qsm.enabled_batches,'[1,2]'::jsonb)))
            AND q.question_type IN (SELECT value FROM jsonb_array_elements_text(coalesce(qsm.enabled_question_types,'["mcq","true_false","essay"]'::jsonb)))
        ) AS question_count,
        EXISTS(
          SELECT 1 FROM public.study_summary_entitlements e
          WHERE e.student_id=v_student_id
            AND e.summary_id=(SELECT min(pi0.summary_id::text)::uuid FROM public.study_summary_package_items pi0 WHERE pi0.package_id=p.id)
            AND e.revoked_at IS NULL AND e.starts_at<=now()
            AND (e.expires_at IS NULL OR e.expires_at>now())
        ) AS has_representative_access,
        (SELECT max(e.expires_at) FROM public.study_summary_entitlements e
          WHERE e.student_id=v_student_id
            AND e.summary_id=(SELECT min(pi0.summary_id::text)::uuid FROM public.study_summary_package_items pi0 WHERE pi0.package_id=p.id)
            AND e.revoked_at IS NULL AND e.starts_at<=now()
            AND (e.expires_at IS NULL OR e.expires_at>now())
        ) AS expires_at
      FROM public.study_summary_package_items pi
      JOIN public.study_summary_packages p ON p.id=pi.package_id AND p.is_active=true
      WHERE pi.summary_id=sm.id
      LIMIT 1
    ) pkg ON true
    WHERE sm.is_published=true AND sm.is_approved=true
      AND (sm.available_from IS NULL OR sm.available_from<=now())
      AND ((sm.available_until IS NULL OR sm.available_until>now()) OR EXISTS(
        SELECT 1 FROM public.study_summary_entitlements e
        WHERE e.student_id=v_student_id AND e.summary_id=sm.id AND e.revoked_at IS NULL
          AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())
      ))
      AND (coalesce(sm.target_all,true) OR (
        (nullif(btrim(sm.target_branch),'') IS NOT NULL OR nullif(btrim(sm.target_system),'') IS NOT NULL OR nullif(btrim(sm.target_batch),'') IS NOT NULL)
        AND public.study_summary_target_matches(sm.target_branch,st.branch)
        AND public.study_summary_target_matches(sm.target_system,st.system_name)
        AND public.study_summary_target_matches(sm.target_batch,st.program)
      ))
      AND (pkg.package_id IS NULL OR sm.id=pkg.representative_id)
  ) x;

  INSERT INTO public.study_summary_activity(student_id,event_type,metadata)
  VALUES(v_student_id,'list','{}'::jsonb);

  RETURN jsonb_build_object('ok',true,'summaries',v_result);
END;
$$;


ALTER FUNCTION "public"."student_list_study_summaries"("p_session_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_list_study_summary_orders"("p_session_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_student_id text;v_result jsonb;begin select s.student_id into v_student_id from public.competition_face_verified_sessions s join public.students st on st.id=s.student_id where s.token=p_session_token and s.competition_type='student_portal' and s.expires_at>now() and st.deleted_at is null and coalesce(st.student_status,'active')='active' limit 1;if v_student_id is null then return jsonb_build_object('ok',false,'reason','session_expired');end if;update public.study_summary_orders set status='expired',updated_at=now() where student_id=v_student_id and status='pending_payment' and expires_at is not null and expires_at<=now();select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'order_number',coalesce(o.order_code,upper(left(replace(o.id::text,'-',''),12))),'order_code',o.order_code,'summary_title',coalesce(p.name,sm.title),'amount',o.amount,'status',o.status,'created_at',o.created_at,'expires_at',o.expires_at,'access_hours',o.access_hours,'payment_reference',o.payment_reference,'payment_provider',sm.payment_provider,'payment_wallet_number',sm.payment_wallet_number) order by o.created_at desc),'[]'::jsonb) into v_result from public.study_summary_orders o join public.study_summaries sm on sm.id=o.summary_id left join public.study_summary_package_items pi on pi.summary_id=sm.id left join public.study_summary_packages p on p.id=pi.package_id and p.is_active=true where o.student_id=v_student_id and coalesce(o.hidden_from_student,false)=false and o.created_at>now()-interval '30 days';return jsonb_build_object('ok',true,'orders',v_result);end;$$;


ALTER FUNCTION "public"."student_list_study_summary_orders"("p_session_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_portal_get_achievements"("p_student_id" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  phone_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  normalized_phone text;
  s public.students%rowtype;
BEGIN
  normalized_phone := CASE
    WHEN phone_digits LIKE '0020%' THEN '0' || substr(phone_digits, 5)
    WHEN phone_digits LIKE '20%' AND length(phone_digits) = 12 THEN '0' || substr(phone_digits, 3)
    WHEN phone_digits LIKE '1%' AND length(phone_digits) = 10 THEN '0' || phone_digits
    ELSE phone_digits
  END;
  IF coalesce(btrim(p_student_id), '') = '' OR normalized_phone = '' THEN RETURN '[]'::jsonb; END IF;

  SELECT * INTO s
  FROM public.students st
  WHERE st.id = btrim(p_student_id)
    AND (
      (CASE
        WHEN regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g'), 5)
        WHEN regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g'), 3)
        WHEN regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')
        ELSE regexp_replace(coalesce(st.phone, ''), '[^0-9]', '', 'g')
      END) = normalized_phone
      OR
      (CASE
        WHEN regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g'), 5)
        WHEN regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g'), 3)
        WHEN regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')
        ELSE regexp_replace(coalesce(st.guardian_phone, ''), '[^0-9]', '', 'g')
      END) = normalized_phone
      OR
      (CASE
        WHEN regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g'), 5)
        WHEN regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g'), 3)
        WHEN regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')
        ELSE regexp_replace(coalesce(st.parent_phone, ''), '[^0-9]', '', 'g')
      END) = normalized_phone
    )
  LIMIT 1;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', a.id, 'achievement_type', a.achievement_type,
      'title', a.title, 'description', a.description,
      'achievement_date', a.achievement_date, 'points', a.points,
      'activity_points', a.activity_points
    ) ORDER BY a.achievement_date DESC, a.created_at DESC)
    FROM public.student_achievements a WHERE a.student_id = s.id
  ), '[]'::jsonb);
END;
$$;


ALTER FUNCTION "public"."student_portal_get_achievements"("p_student_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_portal_get_ranking"("p_student_id" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  phone_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  normalized_phone text;
  matched boolean := false;
  result_data jsonb;
BEGIN
  normalized_phone := CASE
    WHEN phone_digits LIKE '0020%' THEN '0' || substr(phone_digits, 5)
    WHEN phone_digits LIKE '20%' AND length(phone_digits) = 12 THEN '0' || substr(phone_digits, 3)
    WHEN phone_digits LIKE '1%' AND length(phone_digits) = 10 THEN '0' || phone_digits
    ELSE phone_digits
  END;

  SELECT EXISTS (
    SELECT 1 FROM public.students st
    WHERE st.id = btrim(coalesce(p_student_id,''))
      AND (
        regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g') = phone_digits
        OR regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g') = phone_digits
        OR regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g') = phone_digits
        OR (
          CASE
            WHEN regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g'),5)
            WHEN regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g'),3)
            WHEN regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g')
            ELSE regexp_replace(coalesce(st.phone,''), '[^0-9]', '', 'g')
          END
        ) = normalized_phone
        OR (
          CASE
            WHEN regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g'),5)
            WHEN regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g'),3)
            WHEN regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g')
            ELSE regexp_replace(coalesce(st.guardian_phone,''), '[^0-9]', '', 'g')
          END
        ) = normalized_phone
        OR (
          CASE
            WHEN regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g') LIKE '0020%' THEN '0' || substr(regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g'),5)
            WHEN regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g') LIKE '20%' AND length(regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g')) = 12 THEN '0' || substr(regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g'),3)
            WHEN regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g') LIKE '1%' AND length(regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g')) = 10 THEN '0' || regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g')
            ELSE regexp_replace(coalesce(st.parent_phone,''), '[^0-9]', '', 'g')
          END
        ) = normalized_phone
      )
  ) INTO matched;

  IF NOT matched OR normalized_phone = '' THEN RETURN jsonb_build_object('verified', false); END IF;

  WITH student_grade AS (
    SELECT g.student_id,
      SUM(CASE WHEN g.grade_1 IS NOT NULL THEN COALESCE(s.max_grade_1,0) ELSE 0 END
        + CASE WHEN g.grade_2 IS NOT NULL THEN COALESCE(s.max_grade_2, s.max_grade_1,0) ELSE 0 END) AS max_score,
      SUM(CASE WHEN g.grade_1 IS NOT NULL THEN g.grade_1 ELSE 0 END
        + CASE WHEN g.grade_2 IS NOT NULL THEN g.grade_2 ELSE 0 END) AS score,
      COUNT(*) FILTER (WHERE g.grade_1 IS NOT NULL OR g.grade_2 IS NOT NULL) AS graded_count
    FROM public.grades g JOIN public.subjects s ON s.id = g.subject_id
    GROUP BY g.student_id
  ), attendance_score AS (
    SELECT student_id,
      COUNT(*) FILTER (WHERE status IN ('حاضر','غائب')) AS counted,
      COUNT(*) FILTER (WHERE status = 'حاضر') AS present
    FROM public.attendance GROUP BY student_id
  ), achievement_score AS (
    SELECT student_id, LEAST(100, SUM(COALESCE(points,0))) AS achievement,
      LEAST(100, SUM(COALESCE(activity_points,0))) AS activity
    FROM public.student_achievements GROUP BY student_id
  ), components AS (
    SELECT st.id, st.name,
      CASE WHEN COALESCE(sg.max_score,0) > 0 AND COALESCE(sg.graded_count,0)>0 THEN ROUND(sg.score / sg.max_score * 100) ELSE NULL END AS exam_pct,
      CASE WHEN COALESCE(att.counted,0)>0 THEN ROUND(att.present::numeric / att.counted * 100) ELSE NULL END AS attendance_pct,
      COALESCE(ach.achievement,0) AS achievement_pct,
      COALESCE(ach.activity,0) AS activity_pct
    FROM public.students st
    LEFT JOIN student_grade sg ON sg.student_id=st.id
    LEFT JOIN attendance_score att ON att.student_id=st.id
    LEFT JOIN achievement_score ach ON ach.student_id=st.id
    WHERE st.deleted_at IS NULL
  ), scored AS (
    SELECT *,
      CASE WHEN exam_pct IS NULL AND attendance_pct IS NULL THEN
        CASE WHEN achievement_pct=0 AND activity_pct=0 THEN NULL ELSE ROUND((achievement_pct*15 + activity_pct*10)::numeric / 25) END
      ELSE ROUND((
        COALESCE(exam_pct*50,0) + COALESCE(attendance_pct*25,0) + achievement_pct*15 + activity_pct*10
      )::numeric /
      ((CASE WHEN exam_pct IS NULL THEN 0 ELSE 50 END) +
       (CASE WHEN attendance_pct IS NULL THEN 0 ELSE 25 END) + 25))
      END AS total_pct
    FROM components
  ), ranked AS (
    SELECT *, RANK() OVER (ORDER BY total_pct DESC NULLS LAST, name ASC) AS rank_num,
      COUNT(*) FILTER (WHERE total_pct IS NOT NULL) OVER () AS ranked_count
    FROM scored
  )
  SELECT jsonb_build_object(
    'verified', true,
    'rank', rank_num,
    'total', total_pct,
    'exam', exam_pct,
    'attendance', attendance_pct,
    'achievement', achievement_pct,
    'activity', activity_pct,
    'ranked_count', ranked_count
  ) INTO result_data
  FROM ranked WHERE id = btrim(p_student_id);

  RETURN COALESCE(result_data, jsonb_build_object('verified', true, 'rank', null, 'total', null, 'ranked_count', 0));
END;
$$;


ALTER FUNCTION "public"."student_portal_get_ranking"("p_student_id" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_record_study_summary_payment_proof"("p_session_token" "uuid", "p_order_id" "uuid", "p_proof_path" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_student_id text; v_order public.study_summary_orders%rowtype; v_prefix text;
BEGIN
 SELECT s.student_id INTO v_student_id FROM public.competition_face_verified_sessions s
 JOIN public.students st ON st.id=s.student_id
 WHERE s.token=p_session_token AND s.competition_type='student_portal' AND s.expires_at>now()
 AND st.deleted_at IS NULL AND coalesce(st.student_status,'active')='active' LIMIT 1;
 IF v_student_id IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','session_expired'); END IF;
 SELECT * INTO v_order FROM public.study_summary_orders WHERE id=p_order_id AND student_id=v_student_id FOR UPDATE;
 IF NOT FOUND OR v_order.status<>'pending_payment' OR (v_order.expires_at IS NOT NULL AND v_order.expires_at<=now()) THEN
  RETURN jsonb_build_object('ok',false,'reason','order_unavailable');
 END IF;
 v_prefix:=p_session_token::text||'/'||p_order_id::text||'/';
 IF p_proof_path IS NULL OR left(p_proof_path,length(v_prefix))<>v_prefix OR length(p_proof_path)>500 THEN
  RETURN jsonb_build_object('ok',false,'reason','invalid_proof_path');
 END IF;
 UPDATE public.study_summary_orders SET payment_proof_path=p_proof_path,updated_at=now() WHERE id=p_order_id;
 INSERT INTO public.study_summary_activity(student_id,summary_id,order_id,event_type,metadata)
 VALUES(v_student_id,v_order.summary_id,p_order_id,'payment_proof_submitted',
 jsonb_build_object('proof_path',p_proof_path,'order_code',v_order.order_code));
 RETURN jsonb_build_object('ok',true,'status','pending_payment');
END;$$;


ALTER FUNCTION "public"."student_record_study_summary_payment_proof"("p_session_token" "uuid", "p_order_id" "uuid", "p_proof_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."student_submit_study_summary_payment_reference"("p_session_token" "uuid", "p_order_id" "uuid", "p_payment_reference" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_student_id text;
  v_order public.study_summary_orders%rowtype;
  v_reference text := btrim(coalesce(p_payment_reference, ''));
begin
  select s.student_id into v_student_id
  from public.competition_face_verified_sessions s
  join public.students st on st.id = s.student_id
  where s.token = p_session_token
    and s.competition_type = 'student_portal'
    and s.expires_at > now()
    and st.deleted_at is null
    and coalesce(st.student_status, 'active') = 'active'
  limit 1;

  if v_student_id is null then
    return jsonb_build_object('ok', false, 'reason', 'session_expired');
  end if;

  if length(v_reference) < 3 or length(v_reference) > 120 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_reference');
  end if;

  select * into v_order
  from public.study_summary_orders
  where id = p_order_id and student_id = v_student_id
  for update;

  if not found or v_order.status <> 'pending_payment'
     or (v_order.expires_at is not null and v_order.expires_at <= now()) then
    return jsonb_build_object('ok', false, 'reason', 'order_unavailable');
  end if;

  update public.study_summary_orders
  set payment_reference = v_reference, updated_at = now()
  where id = p_order_id;

  insert into public.study_summary_activity (
    student_id, summary_id, order_id, event_type, metadata
  ) values (
    v_student_id, v_order.summary_id, p_order_id, 'payment_reference_submitted',
    jsonb_build_object('order_code', v_order.order_code, 'payment_reference', v_reference)
  );

  return jsonb_build_object('ok', true, 'status', 'pending_payment');
end;
$$;


ALTER FUNCTION "public"."student_submit_study_summary_payment_reference"("p_session_token" "uuid", "p_order_id" "uuid", "p_payment_reference" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."study_summary_questions_default_selected"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  new.is_approved := true;
  new.is_selected := coalesce(new.is_selected,true);
  return new;
end;
$$;


ALTER FUNCTION "public"."study_summary_questions_default_selected"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."study_summary_target_matches"("p_target" "text", "p_student_value" "text") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_targets jsonb;
  v_student text := regexp_replace(lower(btrim(coalesce(p_student_value,''))), '\s+', ' ', 'g');
BEGIN
  IF nullif(btrim(p_target), '') IS NULL THEN
    RETURN true;
  END IF;
  IF left(btrim(p_target), 1) = '[' THEN
    BEGIN
      v_targets := p_target::jsonb;
      IF jsonb_typeof(v_targets) = 'array' THEN
        RETURN EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(v_targets) AS target_value(value)
          WHERE regexp_replace(lower(btrim(target_value.value)), '\s+', ' ', 'g') = v_student
        );
      END IF;
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END IF;
  RETURN regexp_replace(lower(btrim(p_target)), '\s+', ' ', 'g') = v_student;
END;
$$;


ALTER FUNCTION "public"."study_summary_target_matches"("p_target" "text", "p_student_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_public_competition_entry"("p_competition_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answer_text" "text", "p_photo_url" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE st public.students%rowtype; c public.competitions%rowtype; entry_id uuid;
BEGIN
  IF NOT public.student_face_phone_matches(p_student_id,p_phone)
    OR NOT EXISTS (SELECT 1 FROM public.competition_face_verified_sessions fs
      WHERE fs.token=p_face_token AND fs.student_id=btrim(p_student_id)
        AND fs.competition_type='public_competition'
        AND fs.competition_id=p_competition_id::text AND fs.expires_at>now()) THEN
    RETURN jsonb_build_object('ok',false,'reason','verification_required');
  END IF;
  SELECT * INTO st FROM public.students
  WHERE id=btrim(p_student_id) AND deleted_at IS NULL AND coalesce(student_status,'active')='active'
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','student_not_found'); END IF;
  SELECT * INTO c FROM public.competitions
  WHERE id=p_competition_id AND active IS TRUE
    AND (start_date IS NULL OR start_date <= (now() AT TIME ZONE 'Africa/Cairo')::date)
    AND (end_date IS NULL OR end_date >= (now() AT TIME ZONE 'Africa/Cairo')::date)
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','competition_unavailable'); END IF;
  IF c.branch IS NOT NULL AND c.branch<>st.branch THEN RETURN jsonb_build_object('ok',false,'reason','branch_not_allowed'); END IF;
  IF coalesce(length(btrim(p_answer_text)),0)=0 AND coalesce(length(btrim(p_photo_url)),0)=0 THEN
    RETURN jsonb_build_object('ok',false,'reason','entry_required');
  END IF;
  IF p_photo_url IS NOT NULL AND (length(p_photo_url)>1200 OR p_photo_url !~* '^https://') THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_photo_url');
  END IF;
  IF EXISTS (SELECT 1 FROM public.competition_entries WHERE competition_id=c.id AND student_id=st.id) THEN
    RETURN jsonb_build_object('ok',false,'reason','already_submitted');
  END IF;
  INSERT INTO public.competition_entries(competition_id,student_id,answer_text,photo_url,face_verification_token)
  VALUES(c.id,st.id,nullif(btrim(p_answer_text),''),nullif(btrim(p_photo_url),''),p_face_token)
  RETURNING id INTO entry_id;
  RETURN jsonb_build_object('ok',true,'entry_id',entry_id);
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('ok',false,'reason','already_submitted');
END;
$$;


ALTER FUNCTION "public"."submit_public_competition_entry"("p_competition_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answer_text" "text", "p_photo_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_student_request"("p_student_id" "text", "p_phone" "text", "p_requester_type" "text", "p_request_type" "text", "p_title" "text", "p_description" "text", "p_priority" "text" DEFAULT 'normal'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  s public.students%rowtype;
  normalized_phone text := public.normalize_eg_phone(p_phone);
  new_id uuid;
  daily_count integer;
  requester_name_value text;
BEGIN
  p_requester_type := lower(btrim(coalesce(p_requester_type,'')));
  p_request_type := lower(btrim(coalesce(p_request_type,'')));
  p_priority := lower(btrim(coalesce(p_priority,'normal')));

  IF coalesce(btrim(p_student_id),'') = '' OR normalized_phone = '' THEN
    RETURN jsonb_build_object('success',false,'error','identity_required');
  END IF;
  IF p_requester_type NOT IN ('student','parent') THEN
    RETURN jsonb_build_object('success',false,'error','invalid_requester_type');
  END IF;
  IF p_request_type NOT IN ('complaint','request','academic','financial','technical','other') THEN
    RETURN jsonb_build_object('success',false,'error','invalid_request_type');
  END IF;
  IF p_priority NOT IN ('normal','high','urgent') THEN
    RETURN jsonb_build_object('success',false,'error','invalid_priority');
  END IF;
  IF length(btrim(coalesce(p_title,''))) NOT BETWEEN 3 AND 150
     OR length(btrim(coalesce(p_description,''))) NOT BETWEEN 5 AND 3000 THEN
    RETURN jsonb_build_object('success',false,'error','invalid_content');
  END IF;

  SELECT st.* INTO s
  FROM public.students st
  WHERE st.id = btrim(p_student_id)
    AND st.deleted_at IS NULL
    AND (
      public.normalize_eg_phone(st.phone) = normalized_phone
      OR public.normalize_eg_phone(st.guardian_phone) = normalized_phone
      OR public.normalize_eg_phone(st.parent_phone) = normalized_phone
    )
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success',false,'error','identity_not_verified');
  END IF;

  SELECT count(*) INTO daily_count
  FROM public.student_requests r
  WHERE r.student_id = s.id
    AND r.requester_phone = normalized_phone
    AND r.created_at >= now() - interval '24 hours';
  IF daily_count >= 5 THEN
    RETURN jsonb_build_object('success',false,'error','daily_limit');
  END IF;

  requester_name_value := CASE
    WHEN p_requester_type = 'student' THEN s.name
    ELSE coalesce(s.guardian_name, s.parent_name, 'ولي الأمر')
  END;

  INSERT INTO public.student_requests(
    student_id, requester_type, requester_name, requester_phone,
    request_type, title, description, priority, branch, program
  ) VALUES (
    s.id, p_requester_type, requester_name_value, normalized_phone,
    p_request_type, btrim(p_title), btrim(p_description), p_priority,
    s.branch, s.program
  ) RETURNING id INTO new_id;

  RETURN jsonb_build_object('success',true,'id',new_id,'status','new');
END;
$$;


ALTER FUNCTION "public"."submit_student_request"("p_student_id" "text", "p_phone" "text", "p_requester_type" "text", "p_request_type" "text", "p_title" "text", "p_description" "text", "p_priority" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_daily_revenue_to_student_finance"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  is_installment boolean;
  payment_kind text;
begin
  is_installment := coalesce(new.details, '') ilike '%قسط%';
  payment_kind := 'daily_revenue:' || new.id::text;

  if new.student_id is not null and btrim(new.student_id) <> '' then
    insert into public.payments (
      student_id, payment_type, label, amount, paid, paid_date,
      applicable, is_discount, notes, created_by, created_at, updated_at
    ) values (
      new.student_id,
      payment_kind,
      coalesce(nullif(btrim(new.details), ''), 'إيراد يومي'),
      new.amount,
      true,
      coalesce(new.revenue_date, current_date),
      is_installment,
      false,
      'تم تسجيله تلقائيًا من الإيراد اليومي' || case when is_installment then ' — محسوب ضمن المصروفات' else ' — لا يُخصم من إجمالي المصروفات' end,
      new.created_by,
      coalesce(new.created_at, now()),
      now()
    )
    on conflict (student_id, payment_type) do nothing;

    if is_installment then
      update public.students
      set total_due = greatest(coalesce(total_due, 0) - new.amount, 0)
      where id = new.student_id;
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_daily_revenue_to_student_finance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_student_status_when_procedure_is_dismissal"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_user uuid := auth.uid();
begin
  if new.type = 'فصل' then
    update public.students
       set student_status = 'dismissed',
           dismissed_at = coalesce(dismissed_at, now()),
           dismissed_by = coalesce(v_user, dismissed_by),
           deleted_at = null,
           deleted_by = null
     where id = new.student_id
       and coalesce(student_status, 'active') not in ('dismissed','final_dismissed');

    if found then
      insert into public.student_disciplinary_actions
        (student_id, action_type, action_date, decision_number, reason, notes, created_by)
      values
        (new.student_id,
         'dismissal',
         case when new.date ~ '^\d{4}-\d{2}-\d{2}$' then new.date::date else current_date end,
         new.reference_number,
         new.details,
         new.result,
         coalesce(v_user, new.created_by));
    end if;
  end if;
  return new;
end;
$_$;


ALTER FUNCTION "public"."sync_student_status_when_procedure_is_dismissal"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trainer_kiosk_get_attendance"("p_code" "text", "p_session_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  s public.schedule_sessions%rowtype;
  v_today text := (now() AT TIME ZONE 'Africa/Cairo')::date::text;
  v_students jsonb;
  v_excluded jsonb;
  v_attendance jsonb;
BEGIN
  SELECT * INTO s FROM public.schedule_sessions
  WHERE id::text=btrim(p_session_id) AND trainer_code=btrim(coalesce(p_code,''))
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','session_not_authorized'); END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',st.id,'name',st.name,'branch',st.branch,'program_id',st.program_id,
    'program',st.program,'system_name',st.system_name
  ) ORDER BY st.id), '[]'::jsonb)
  INTO v_students
  FROM public.students st
  WHERE st.branch=s.branch AND st.deleted_at IS NULL
    AND coalesce(st.student_status,'active')='active';

  SELECT coalesce(jsonb_agg(e.student_id), '[]'::jsonb)
  INTO v_excluded
  FROM public.attendance_session_exclusions e
  WHERE e.session_id=s.id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'student_id',a.student_id,'status',a.status
  )), '[]'::jsonb)
  INTO v_attendance
  FROM public.attendance a
  WHERE a.session_id=s.id AND a.date=v_today;

  RETURN jsonb_build_object('ok',true,'students',v_students,'excluded_ids',v_excluded,'attendance',v_attendance,'date',v_today);
END;
$$;


ALTER FUNCTION "public"."trainer_kiosk_get_attendance"("p_code" "text", "p_session_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trainer_kiosk_get_sessions"("p_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE result_data jsonb;
BEGIN
  IF length(btrim(coalesce(p_code,''))) < 4 THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_code');
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'day',s.day,'day_order',s.day_order,'start_time',s.start_time,'end_time',s.end_time,
    'program_name',s.program_name,'program_id',s.program_id,'system_name',s.system_name,
    'subject_name',s.subject_name,'branch',s.branch,'trainer',s.trainer,'notes',s.notes,
    'program_combos',s.program_combos,'session_date',s.session_date
  ) ORDER BY s.session_date NULLS LAST,s.day_order NULLS LAST,s.start_time), '[]'::jsonb)
  INTO result_data
  FROM public.schedule_sessions s
  WHERE s.trainer_code = btrim(p_code);
  IF result_data = '[]'::jsonb THEN
    RETURN jsonb_build_object('ok',false,'reason','not_found');
  END IF;
  RETURN jsonb_build_object('ok',true,'sessions',result_data);
END;
$$;


ALTER FUNCTION "public"."trainer_kiosk_get_sessions"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trainer_kiosk_mark_attendance"("p_code" "text", "p_session_id" "text", "p_student_id" "text", "p_status" "text", "p_date" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  s public.schedule_sessions%rowtype;
  st public.students%rowtype;
  v_today text := (now() AT TIME ZONE 'Africa/Cairo')::date::text;
BEGIN
  IF p_status NOT IN ('حاضر','غائب','استئذان') OR btrim(coalesce(p_student_id,''))='' THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_data');
  END IF;
  IF p_date IS DISTINCT FROM v_today THEN
    RETURN jsonb_build_object('ok',false,'reason','date_not_allowed');
  END IF;
  SELECT * INTO s FROM public.schedule_sessions
  WHERE id::text=btrim(p_session_id) AND trainer_code=btrim(coalesce(p_code,''))
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','session_not_authorized'); END IF;
  SELECT * INTO st FROM public.students
  WHERE id=btrim(p_student_id) AND branch=s.branch AND deleted_at IS NULL
    AND coalesce(student_status,'active')='active'
  LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','student_not_allowed'); END IF;
  IF EXISTS (SELECT 1 FROM public.attendance_session_exclusions e WHERE e.session_id=s.id AND e.student_id=st.id) THEN
    RETURN jsonb_build_object('ok',false,'reason','student_excluded');
  END IF;
  INSERT INTO public.attendance(student_id,session_id,date,status,recorded_by)
  VALUES(st.id,s.id,v_today,p_status,NULL)
  ON CONFLICT(student_id,session_id,date)
  DO UPDATE SET status=EXCLUDED.status
  RETURNING id INTO s.id;
  RETURN jsonb_build_object('ok',true,'student_id',st.id,'status',p_status,'date',v_today);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok',false,'reason','save_failed');
END;
$$;


ALTER FUNCTION "public"."trainer_kiosk_mark_attendance"("p_code" "text", "p_session_id" "text", "p_student_id" "text", "p_status" "text", "p_date" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_study_summary_order"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_price numeric;
  v_package_id uuid;
BEGIN
  SELECT pi.package_id INTO v_package_id
  FROM public.study_summary_package_items pi
  WHERE pi.summary_id = NEW.summary_id
  LIMIT 1;

  IF v_package_id IS NOT NULL THEN
    SELECT p.price INTO v_price
    FROM public.study_summary_packages p
    WHERE p.id = v_package_id AND p.is_active = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'الباقة غير متاحة للشراء';
    END IF;
  ELSE
    SELECT s.price INTO v_price
    FROM public.study_summaries s
    WHERE s.id = NEW.summary_id
      AND s.is_published = true
      AND s.is_approved = true
      AND (s.available_from IS NULL OR s.available_from <= now())
      AND (s.available_until IS NULL OR s.available_until > now());

    IF NOT FOUND THEN
      RAISE EXCEPTION 'الملخص غير متاح للشراء';
    END IF;
  END IF;

  -- Price is calculated server-side; never trust a client-supplied amount.
  NEW.amount := v_price;
  NEW.status := 'pending_payment';
  NEW.payment_method := coalesce(nullif(trim(NEW.payment_method), ''), 'manual_transfer');

  -- A transaction reference is intentionally optional at order creation.
  -- It is recorded later by student_submit_study_summary_payment_reference.
  NEW.payment_reference := nullif(trim(coalesce(NEW.payment_reference, '')), '');
  NEW.payment_number := nullif(trim(coalesce(NEW.payment_number, '')), '');

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."validate_study_summary_order"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."verify_certificate_by_serial"("p_serial" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT CASE WHEN p_serial IS NULL OR length(btrim(p_serial)) < 4 THEN NULL
    ELSE (
      SELECT jsonb_build_object(
        'serial', c.serial,
        'student_name', c.student_name,
        'program_name', c.program_name,
        'system_name', c.system_name,
        'branch', c.branch,
        'issued_at', c.issued_at
      )
      FROM public.certificate_records c
      WHERE c.serial = btrim(p_serial)
      LIMIT 1
    )
  END;
$$;


ALTER FUNCTION "public"."verify_certificate_by_serial"("p_serial" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."weekly_quiz_admin_audit"("p_limit" integer DEFAULT 200) RETURNS TABLE("id" "uuid", "student_id" "text", "student_name" "text", "photo_path" "text", "user_agent" "text", "browser_name" "text", "device_label" "text", "entered_at" timestamp with time zone, "photo_consent_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.user_profiles p
    where p.id = auth.uid() and p.role = 'admin' and p.is_active = true
  ) then
    raise exception 'admin_only';
  end if;
  return query
  select a.id, a.student_id, a.student_name, a.photo_path, a.user_agent,
         a.browser_name, a.device_label, a.entered_at, a.photo_consent_at
  from public.weekly_quiz_access_audit a
  order by a.entered_at desc
  limit greatest(1, least(coalesce(p_limit,200),500));
end;
$$;


ALTER FUNCTION "public"."weekly_quiz_admin_audit"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."weekly_quiz_get_answered_questions"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE answers_data jsonb; session_ok boolean:=false;
BEGIN
  IF coalesce(btrim(p_student_id),'')='' OR p_face_token IS NULL OR p_week_start IS NULL
    OR extract(dow FROM p_week_start)::integer<>6 THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_request');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.students s WHERE s.id=btrim(p_student_id)
    AND s.deleted_at IS NULL AND s.student_status='active') THEN
    RETURN jsonb_build_object('ok',false,'reason','student_not_found');
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.competition_face_verified_sessions s
    WHERE s.token=p_face_token AND s.student_id=btrim(p_student_id)
      AND s.competition_type='weekly_quiz' AND s.expires_at>now()
      AND coalesce(s.verification_method,'') IN ('device','passkey','device_passkey'))
  INTO session_ok;
  IF NOT session_ok THEN
    SELECT EXISTS(SELECT 1 FROM public.weekly_quiz_access_audit a
      WHERE a.student_id=btrim(p_student_id) AND split_part(a.photo_path,'/',3)=p_face_token::text
        AND a.photo_consent_at IS NOT NULL AND a.entered_at>=now()-interval '30 minutes')
    INTO session_ok;
  END IF;
  IF NOT session_ok THEN RETURN jsonb_build_object('ok',false,'reason','session_expired'); END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'quiz_date',qa.quiz_date,'question_id',qa.question_id,
    'selected_option',qa.selected_option,'is_correct',qa.is_correct,
    'points_earned',qa.points_earned,'correct_option',q.correct_option,
    'question_text',q.question,'option_a',q.option_a,'option_b',q.option_b,
    'option_c',q.option_c,'option_d',q.option_d
  ) ORDER BY qa.quiz_date DESC,qa.question_id),'[]'::jsonb)
  INTO answers_data
  FROM public.quiz_answers qa
  LEFT JOIN public.quiz_bank_questions q ON q.id=qa.question_id
  WHERE qa.student_id=btrim(p_student_id)
    AND qa.quiz_date>=p_week_start AND qa.quiz_date<p_week_start+7;

  RETURN jsonb_build_object('ok',true,'answers',answers_data);
END;
$$;


ALTER FUNCTION "public"."weekly_quiz_get_answered_questions"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."weekly_quiz_get_public_questions"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',q.id,'question',q.question,'option_a',q.option_a,'option_b',q.option_b,
    'option_c',q.option_c,'option_d',q.option_d,'category',q.category,'points',10,
    'active',q.active,'created_at',q.created_at) ORDER BY q.created_at DESC),'[]'::jsonb)
  FROM public.quiz_bank_questions q
  WHERE q.active IS TRUE AND EXISTS (
    SELECT 1 FROM public.quiz_daily_sessions ds
    CROSS JOIN LATERAL jsonb_array_elements_text(ds.question_ids) scheduled(id)
    WHERE scheduled.id=q.id::text
      AND ds.quiz_date >= ((now() AT TIME ZONE 'Africa/Cairo')::date - ((extract(dow FROM (now() AT TIME ZONE 'Africa/Cairo')::date)::integer+1)%7))
      AND ds.quiz_date <= (now() AT TIME ZONE 'Africa/Cairo')::date
  );
$$;


ALTER FUNCTION "public"."weekly_quiz_get_public_questions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."weekly_quiz_get_public_scores"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_id text := btrim(coalesce(p_student_id,''));
  v_leaderboard jsonb;
  v_mine jsonb;
BEGIN
  IF v_id = '' OR p_face_token IS NULL OR p_week_start IS NULL
     OR extract(dow FROM p_week_start)::integer <> 6 THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_request');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.students s
    WHERE s.id = v_id AND s.deleted_at IS NULL AND s.student_status = 'active'
  ) THEN
    RETURN jsonb_build_object('ok',false,'reason','student_not_found');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_quiz_access_audit a
    WHERE a.student_id = v_id
      AND split_part(a.photo_path,'/',3) = p_face_token::text
      AND a.photo_consent_at IS NOT NULL
      AND a.entered_at >= now() - interval '30 minutes'
  ) THEN
    RETURN jsonb_build_object('ok',false,'reason','face_verification_required');
  END IF;

  SELECT CASE WHEN q.student_id IS NULL THEN NULL ELSE jsonb_build_object(
    'total_points',q.total_points,'correct_count',q.correct_count,'week_start',q.week_start
  ) END
  INTO v_mine
  FROM (SELECT v_id AS student_id) wanted
  LEFT JOIN public.quiz_weekly_scores q
    ON q.student_id = wanted.student_id AND q.week_start = p_week_start;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'rank', ranked.rank_num,
    'student_name', ranked.student_name,
    'total_points', ranked.total_points,
    'correct_count', ranked.correct_count,
    'is_me', ranked.student_id = v_id
  ) ORDER BY ranked.rank_num), '[]'::jsonb)
  INTO v_leaderboard
  FROM (
    SELECT row_number() OVER (ORDER BY q.total_points DESC, q.correct_count DESC, q.student_name ASC) AS rank_num,
           q.student_id, q.student_name, q.total_points, q.correct_count
    FROM public.quiz_weekly_scores q
    WHERE q.week_start = p_week_start
    ORDER BY q.total_points DESC, q.correct_count DESC, q.student_name ASC
    LIMIT 10
  ) ranked;

  RETURN jsonb_build_object('ok',true,'my_score',v_mine,'leaderboard',v_leaderboard);
END;
$$;


ALTER FUNCTION "public"."weekly_quiz_get_public_scores"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."weekly_quiz_log_entry"("p_student_id" "text", "p_photo_path" "text", "p_face_token" "uuid", "p_user_agent" "text" DEFAULT NULL::"text", "p_browser_name" "text" DEFAULT NULL::"text", "p_device_label" "text" DEFAULT NULL::"text", "p_photo_consent" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'storage'
    AS $_$
DECLARE
  s record;
  consumed_token uuid;
BEGIN
  IF p_photo_consent IS DISTINCT FROM true THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'photo_consent_required');
  END IF;
  IF coalesce(btrim(p_student_id), '') = ''
     OR coalesce(p_photo_path, '') !~ '^audit/[A-Za-z0-9_-]+/[0-9a-fA-F-]{36}/[^/]+$'
     OR p_face_token IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_data');
  END IF;

  SELECT id, name INTO s
  FROM public.students
  WHERE id = btrim(p_student_id) AND deleted_at IS NULL
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'registration_not_found');
  END IF;

  -- Atomically consume the token: it must belong to this student, be for this
  -- weekly quiz flow, and still be within its 30-minute lifetime.
  DELETE FROM public.competition_face_verified_sessions
  WHERE token = p_face_token
    AND student_id = s.id
    AND competition_type = 'weekly_quiz'
    AND expires_at > now()
  RETURNING token INTO consumed_token;
  IF consumed_token IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'face_verification_required_or_expired');
  END IF;

  INSERT INTO public.weekly_quiz_access_audit
    (student_id, student_name, photo_path, user_agent, browser_name, device_label, photo_consent_at)
  VALUES
    (s.id, s.name, p_photo_path, left(p_user_agent, 1000),
     left(p_browser_name, 100), left(p_device_label, 100), now());

  INSERT INTO public.competition_security_logs
    (competition_type, enrollment_number, student_id, event_type, outcome, reason, user_agent, device_label, metadata)
  VALUES
    ('weekly_quiz', s.id, s.id, 'weekly_quiz_entry', 'success', 'face_token_and_photo_consent_verified',
     left(p_user_agent, 1000), left(p_device_label, 100),
     jsonb_build_object('browser', left(p_browser_name, 100), 'photo_path', p_photo_path,
                        'photo_consent', true, 'face_token_consumed', true));

  RETURN jsonb_build_object('ok', true, 'student_id', s.id, 'student_name', s.name);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'weekly_quiz_log_entry failed: %', SQLERRM;
  RETURN jsonb_build_object('ok', false, 'reason', 'audit_write_failed');
END;
$_$;


ALTER FUNCTION "public"."weekly_quiz_log_entry"("p_student_id" "text", "p_photo_path" "text", "p_face_token" "uuid", "p_user_agent" "text", "p_browser_name" "text", "p_device_label" "text", "p_photo_consent" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."weekly_quiz_start_question"("p_student_id" "text", "p_quiz_date" "date", "p_question_id" "uuid", "p_face_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_settings public.golden_league_settings%rowtype;
  v_student public.students%rowtype;
  v_now timestamptz:=now();
  v_local_date date:=(now() AT TIME ZONE 'Africa/Cairo')::date;
  v_local_time time:=(now() AT TIME ZONE 'Africa/Cairo')::time;
  v_week integer; v_seconds integer; v_started timestamptz; v_existing uuid;
BEGIN
  SELECT * INTO v_settings FROM public.golden_league_settings WHERE id=1;
  IF NOT FOUND OR NOT v_settings.active THEN RETURN jsonb_build_object('ok',false,'reason','league_inactive'); END IF;
  IF p_quiz_date<>v_local_date OR NOT (extract(dow FROM v_local_date)::integer=ANY(v_settings.allowed_days)) THEN
    RETURN jsonb_build_object('ok',false,'reason','closed_day');
  END IF;
  IF v_local_time<v_settings.daily_start OR v_local_time>=v_settings.daily_end THEN
    RETURN jsonb_build_object('ok',false,'reason',CASE WHEN v_local_time<v_settings.daily_start THEN 'not_started' ELSE 'ended' END);
  END IF;
  SELECT * INTO v_student FROM public.students WHERE id=btrim(p_student_id) AND deleted_at IS NULL AND student_status='active';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','student_not_found'); END IF;
  IF p_face_token IS NULL OR NOT (
    EXISTS(SELECT 1 FROM public.competition_face_verified_sessions s WHERE s.token=p_face_token AND s.student_id=v_student.id
      AND s.competition_type='weekly_quiz' AND s.expires_at>v_now AND coalesce(s.verification_method,'') IN ('device','passkey','device_passkey'))
    OR EXISTS(SELECT 1 FROM public.weekly_quiz_access_audit a WHERE a.student_id=v_student.id
      AND split_part(a.photo_path,'/',3)=p_face_token::text AND a.photo_consent_at IS NOT NULL AND a.entered_at>=v_now-interval '30 minutes')
  ) THEN RETURN jsonb_build_object('ok',false,'reason','session_expired'); END IF;
  v_week:=public.golden_league_week_number(v_local_date);
  IF v_week NOT BETWEEN 1 AND 4 THEN RETURN jsonb_build_object('ok',false,'reason','off_cycle'); END IF;
  IF NOT EXISTS(SELECT 1 FROM public.quiz_daily_sessions ds WHERE ds.quiz_date=p_quiz_date
    AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(ds.question_ids) q(id) WHERE q.id=p_question_id::text))
  THEN RETURN jsonb_build_object('ok',false,'reason','question_not_scheduled'); END IF;
  IF EXISTS(SELECT 1 FROM public.quiz_answers a WHERE a.student_id=v_student.id AND a.quiz_date=p_quiz_date AND a.question_id=p_question_id)
  THEN RETURN jsonb_build_object('ok',false,'reason','already_answered'); END IF;
  v_seconds:=v_settings.weekly_seconds[v_week];
  INSERT INTO public.golden_league_question_starts(student_id,quiz_date,question_id,face_token,started_at)
  VALUES(v_student.id,p_quiz_date,p_question_id,p_face_token,v_now)
  ON CONFLICT(student_id,quiz_date,question_id) DO UPDATE SET face_token=EXCLUDED.face_token;
  SELECT started_at INTO v_started FROM public.golden_league_question_starts
    WHERE student_id=v_student.id AND quiz_date=p_quiz_date AND question_id=p_question_id AND face_token=p_face_token;
  IF v_started IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','question_session_conflict'); END IF;
  RETURN jsonb_build_object('ok',true,'started_at',v_started,'seconds',v_seconds,
    'remaining_seconds',greatest(0,ceil(v_seconds-extract(epoch FROM (v_now-v_started)))::integer));
END;
$$;


ALTER FUNCTION "public"."weekly_quiz_start_question"("p_student_id" "text", "p_quiz_date" "date", "p_question_id" "uuid", "p_face_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."weekly_quiz_submit_answer"("p_quiz_date" "date", "p_student_id" "text", "p_question_id" "uuid", "p_selected_option" "text", "p_face_token" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_question record; v_student record; v_correct boolean:=false; v_points integer:=0; v_inserted uuid;
  v_week_start date; v_total integer:=0; v_correct_count integer:=0; v_session_ok boolean:=false;
  v_settings public.golden_league_settings%rowtype; v_start timestamptz; v_seconds integer;
  v_local_date date:=(now() AT TIME ZONE 'Africa/Cairo')::date;
  v_local_time time:=(now() AT TIME ZONE 'Africa/Cairo')::time; v_week integer;
BEGIN
  IF p_quiz_date IS NULL OR coalesce(btrim(p_student_id),'')='' OR p_question_id IS NULL OR p_face_token IS NULL
    OR (p_selected_option IS NOT NULL AND p_selected_option NOT IN ('a','b','c','d')) THEN
    RETURN jsonb_build_object('ok',false,'reason','invalid_data');
  END IF;
  SELECT id,name INTO v_student FROM public.students WHERE id=btrim(p_student_id) AND deleted_at IS NULL AND student_status='active' LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','student_not_found'); END IF;
  SELECT * INTO v_settings FROM public.golden_league_settings WHERE id=1;
  IF NOT FOUND OR NOT v_settings.active THEN RETURN jsonb_build_object('ok',false,'reason','league_inactive'); END IF;
  IF p_quiz_date<>v_local_date OR NOT (extract(dow FROM v_local_date)::integer=ANY(v_settings.allowed_days))
    OR v_local_time<v_settings.daily_start OR v_local_time>=v_settings.daily_end THEN
    RETURN jsonb_build_object('ok',false,'reason','outside_time_window');
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.competition_face_verified_sessions s
    WHERE s.token=p_face_token AND s.student_id=v_student.id AND s.competition_type='weekly_quiz'
      AND s.expires_at>now() AND coalesce(s.verification_method,'') IN ('device','passkey','device_passkey')
  ) INTO v_session_ok;
  IF NOT v_session_ok THEN
    SELECT EXISTS (SELECT 1 FROM public.weekly_quiz_access_audit a WHERE a.student_id=v_student.id
      AND split_part(a.photo_path,'/',3)=p_face_token::text AND a.photo_consent_at IS NOT NULL
      AND a.entered_at>=now()-interval '30 minutes') INTO v_session_ok;
  END IF;
  IF NOT v_session_ok THEN RETURN jsonb_build_object('ok',false,'reason','session_expired'); END IF;
  v_week:=public.golden_league_week_number(v_local_date);
  IF v_week NOT BETWEEN 1 AND 4 THEN RETURN jsonb_build_object('ok',false,'reason','off_cycle'); END IF;
  v_seconds:=v_settings.weekly_seconds[v_week];
  SELECT started_at INTO v_start FROM public.golden_league_question_starts
    WHERE student_id=v_student.id AND quiz_date=p_quiz_date AND question_id=p_question_id AND face_token=p_face_token;
  IF v_start IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','question_not_started'); END IF;
  IF extract(epoch FROM (now()-v_start))>v_seconds+1 AND p_selected_option IS NOT NULL THEN
    RETURN jsonb_build_object('ok',false,'reason','time_expired');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.quiz_daily_sessions ds WHERE ds.quiz_date=p_quiz_date
    AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(ds.question_ids) q(id) WHERE q.id=p_question_id::text))
  THEN RETURN jsonb_build_object('ok',false,'reason','question_not_scheduled'); END IF;
  SELECT id,correct_option INTO v_question FROM public.quiz_bank_questions
    WHERE id=p_question_id AND coalesce(active,true)=true LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'reason','question_unavailable'); END IF;
  v_correct:=p_selected_option IS NOT NULL AND p_selected_option=v_question.correct_option;
  v_points:=CASE WHEN v_correct THEN v_settings.points_per_question ELSE 0 END;
  INSERT INTO public.quiz_answers(quiz_date,student_id,question_id,selected_option,is_correct,points_earned,face_verification_token)
  VALUES(p_quiz_date,v_student.id,p_question_id,p_selected_option,v_correct,v_points,p_face_token)
  ON CONFLICT(quiz_date,student_id,question_id) DO NOTHING RETURNING id INTO v_inserted;
  IF v_inserted IS NULL THEN RETURN jsonb_build_object('ok',false,'reason','already_answered'); END IF;
  v_week_start:=p_quiz_date-((extract(dow FROM p_quiz_date)::integer+1)%7);
  SELECT coalesce(sum(points_earned),0),count(*) FILTER(WHERE is_correct=true) INTO v_total,v_correct_count
    FROM public.quiz_answers WHERE student_id=v_student.id AND quiz_date>=v_week_start AND quiz_date<v_week_start+7;
  INSERT INTO public.quiz_weekly_scores(student_id,student_name,week_start,total_points,correct_count,updated_at)
  VALUES(v_student.id,v_student.name,v_week_start,v_total,v_correct_count,now())
  ON CONFLICT(student_id,week_start) DO UPDATE SET student_name=EXCLUDED.student_name,total_points=EXCLUDED.total_points,
    correct_count=EXCLUDED.correct_count,updated_at=now();
  RETURN jsonb_build_object('ok',true,'is_correct',v_correct,'points_earned',v_points,'correct_option',v_question.correct_option,
    'total_points',v_total,'correct_count',v_correct_count,'seconds',v_seconds);
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'weekly_quiz_submit_answer failed: %',SQLERRM;
  RETURN jsonb_build_object('ok',false,'reason','submission_failed');
END;
$$;


ALTER FUNCTION "public"."weekly_quiz_submit_answer"("p_quiz_date" "date", "p_student_id" "text", "p_question_id" "uuid", "p_selected_option" "text", "p_face_token" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."activity_log" (
    "id" bigint NOT NULL,
    "user_id" "uuid",
    "username" "text",
    "action" "text" NOT NULL,
    "details" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."activity_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."activity_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."activity_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."activity_log_id_seq" OWNED BY "public"."activity_log"."id";



CREATE TABLE IF NOT EXISTS "public"."ai_conversations" (
    "user_id" "uuid" NOT NULL,
    "previous_interaction_id" "text",
    "last_question" "text",
    "last_answer" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ai_conversations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."alumni_placements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "employer_name" "text",
    "job_title" "text",
    "employment_date" "date",
    "salary_range" "text",
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."alumni_placements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."andalus_ai_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "details" "text" DEFAULT ''::"text" NOT NULL,
    "task_type" "text" DEFAULT 'admin'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "run_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "executed_at" timestamp with time zone,
    "result" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "andalus_ai_tasks_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'scheduled'::"text", 'running'::"text", 'completed'::"text", 'failed'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "andalus_ai_tasks_title_check" CHECK ((("char_length"("btrim"("title")) >= 1) AND ("char_length"("btrim"("title")) <= 180)))
);


ALTER TABLE "public"."andalus_ai_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text",
    "date" "text" NOT NULL,
    "status" "text" NOT NULL,
    "recorded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "program" "text",
    "session_id" "uuid"
);


ALTER TABLE "public"."attendance" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance_session_exclusions" (
    "session_id" "uuid" NOT NULL,
    "student_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."attendance_session_exclusions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cash_register_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "branch" "text" NOT NULL,
    "log_date" "date" NOT NULL,
    "opening_balance" numeric DEFAULT 0,
    "expected_cash" numeric DEFAULT 0,
    "actual_cash" numeric DEFAULT 0,
    "notes" "text",
    "closed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."cash_register_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."certificate_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "serial" "text" NOT NULL,
    "student_id" "text" NOT NULL,
    "student_name" "text" NOT NULL,
    "program_name" "text",
    "system_name" "text",
    "branch" "text",
    "issued_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."certificate_records" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."certificate_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "image_url" "text" NOT NULL,
    "name_x_pct" numeric DEFAULT 50,
    "name_y_pct" numeric DEFAULT 50,
    "font_size" integer DEFAULT 28,
    "font_color" "text" DEFAULT '#c9a84c'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."certificate_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."competition_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "competition_id" "uuid" NOT NULL,
    "student_id" "text" NOT NULL,
    "answer_text" "text",
    "photo_url" "text",
    "is_winner" boolean DEFAULT false,
    "submitted_at" timestamp with time zone DEFAULT "now"(),
    "face_verification_token" "uuid"
);


ALTER TABLE "public"."competition_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."competition_face_enrollments" (
    "id" bigint NOT NULL,
    "student_id" "text" NOT NULL,
    "enrollment_number" "text" NOT NULL,
    "provider" "text" NOT NULL,
    "provider_subject_id" "text" NOT NULL,
    "consent_at" timestamp with time zone NOT NULL,
    "consent_version" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "face_descriptor" "jsonb",
    "model_version" "text" DEFAULT 'face-api.js-0.22.2'::"text" NOT NULL
);


ALTER TABLE "public"."competition_face_enrollments" OWNER TO "postgres";


ALTER TABLE "public"."competition_face_enrollments" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."competition_face_enrollments_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."competition_face_verified_sessions" (
    "token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "competition_type" "text" NOT NULL,
    "competition_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "verification_method" "text" DEFAULT 'face'::"text" NOT NULL,
    CONSTRAINT "competition_face_verified_sessions_competition_type_check" CHECK (("competition_type" = ANY (ARRAY['weekly_quiz'::"text", 'public_competition'::"text", 'exam_portal'::"text", 'student_portal'::"text"])))
);


ALTER TABLE "public"."competition_face_verified_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."competition_security_logs" (
    "id" bigint NOT NULL,
    "competition_type" "text" NOT NULL,
    "competition_id" "text",
    "enrollment_number" "text",
    "student_id" "text",
    "event_type" "text" NOT NULL,
    "outcome" "text" NOT NULL,
    "reason" "text",
    "ip_address" "inet",
    "user_agent" "text",
    "device_label" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "competition_security_logs_competition_type_check" CHECK (("competition_type" = ANY (ARRAY['weekly_quiz'::"text", 'public_competition'::"text", 'student_portal'::"text", 'exam_portal'::"text", 'identity'::"text"]))),
    CONSTRAINT "competition_security_logs_outcome_check" CHECK (("outcome" = ANY (ARRAY['success'::"text", 'failure'::"text", 'blocked'::"text", 'pending'::"text"])))
);


ALTER TABLE "public"."competition_security_logs" OWNER TO "postgres";


ALTER TABLE "public"."competition_security_logs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."competition_security_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."competitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "branch" "text",
    "start_date" "date",
    "end_date" "date",
    "active" boolean DEFAULT true,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."competitions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."contact_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "contact_type" "text" DEFAULT 'مكالمة'::"text" NOT NULL,
    "subject" "text" NOT NULL,
    "notes" "text",
    "created_by" "uuid",
    "created_by_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."contact_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_revenue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "serial_no" integer NOT NULL,
    "student_id" "text",
    "student_name" "text",
    "amount" numeric NOT NULL,
    "details" "text",
    "branch" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "revenue_date" "date" DEFAULT CURRENT_DATE NOT NULL
);


ALTER TABLE "public"."daily_revenue" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."daily_revenue_serial_no_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."daily_revenue_serial_no_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."daily_revenue_serial_no_seq" OWNED BY "public"."daily_revenue"."serial_no";



CREATE TABLE IF NOT EXISTS "public"."employee_activity_log" (
    "id" bigint NOT NULL,
    "actor_user_id" "uuid",
    "action_type" "text" NOT NULL,
    "module" "text",
    "entity_table" "text",
    "entity_id" "text",
    "title" "text",
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "old_data" "jsonb",
    "new_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employee_activity_log" OWNER TO "postgres";


ALTER TABLE "public"."employee_activity_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."employee_activity_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."employees_full_profile" WITH ("security_invoker"='true') AS
 SELECT "p"."id",
    "p"."username",
    "p"."full_name",
    "u"."email",
    "p"."role",
    "p"."branch",
    "p"."is_active",
    "p"."phone",
    "p"."address",
    "p"."qualification",
    "p"."hiring_date",
    "p"."salary",
    "p"."created_at",
    "u"."last_sign_in_at"
   FROM ("public"."user_profiles" "p"
     JOIN "auth"."users" "u" ON (("u"."id" = "p"."id")));


ALTER VIEW "public"."employees_full_profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exam_attempts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "exam_id" "uuid",
    "student_id" "text" NOT NULL,
    "question_order" "jsonb",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "submitted_at" timestamp with time zone,
    "answers" "jsonb" DEFAULT '{}'::"jsonb",
    "score" numeric,
    "max_score" numeric,
    "status" "text" DEFAULT 'in_progress'::"text" NOT NULL,
    "flagged_cheating" boolean DEFAULT false,
    "time_taken_seconds" integer
);


ALTER TABLE "public"."exam_attempts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exam_questions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "exam_id" "uuid",
    "question_text" "text" NOT NULL,
    "question_type" "text" DEFAULT 'mcq'::"text" NOT NULL,
    "option_a" "text",
    "option_b" "text",
    "option_c" "text",
    "option_d" "text",
    "correct_answer" "text" NOT NULL,
    "points" numeric DEFAULT 1 NOT NULL,
    "order_num" integer DEFAULT 0
);


ALTER TABLE "public"."exam_questions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."exams" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "subject_id" "uuid",
    "program_id" "text",
    "system_name" "text",
    "branch" "text" NOT NULL,
    "round" integer DEFAULT 1 NOT NULL,
    "duration_minutes" integer DEFAULT 30 NOT NULL,
    "available_from" timestamp with time zone NOT NULL,
    "available_until" timestamp with time zone NOT NULL,
    "is_easy_retake" boolean DEFAULT false,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "total_score" numeric DEFAULT 100 NOT NULL,
    "show_answers_after_submit" boolean DEFAULT false,
    "is_placement_test" boolean DEFAULT false,
    "program_combos" "jsonb"
);


ALTER TABLE "public"."exams" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."expenses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "branch" "text" NOT NULL,
    "item" "text" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "expense_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "deduct" boolean DEFAULT true,
    CONSTRAINT "expenses_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "expenses_branch_check" CHECK (("branch" = ANY (ARRAY['كفر الدوار'::"text", 'فيكتوريا'::"text"])))
);


ALTER TABLE "public"."expenses" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."expense_totals" WITH ("security_invoker"='true') AS
 SELECT "branch",
    ("date_trunc"('day'::"text", ("expense_date")::timestamp with time zone))::"date" AS "day",
    ("date_trunc"('month'::"text", ("expense_date")::timestamp with time zone))::"date" AS "month",
    ("date_trunc"('year'::"text", ("expense_date")::timestamp with time zone))::"date" AS "year",
    ("sum"("amount"))::numeric(12,2) AS "total",
    ("count"(*))::integer AS "expense_count"
   FROM "public"."expenses"
  GROUP BY "branch", (("date_trunc"('day'::"text", ("expense_date")::timestamp with time zone))::"date"), (("date_trunc"('month'::"text", ("expense_date")::timestamp with time zone))::"date"), (("date_trunc"('year'::"text", ("expense_date")::timestamp with time zone))::"date");


ALTER VIEW "public"."expense_totals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gallery_albums" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "branch" "text",
    "event_date" "date",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."gallery_albums" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gallery_photos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "album_id" "uuid",
    "photo_url" "text" NOT NULL,
    "caption" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."gallery_photos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."golden_league_question_starts" (
    "student_id" "text" NOT NULL,
    "quiz_date" "date" NOT NULL,
    "question_id" "uuid" NOT NULL,
    "face_token" "uuid" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."golden_league_question_starts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."golden_league_settings" (
    "id" integer DEFAULT 1 NOT NULL,
    "title" "text" DEFAULT 'دوري الأندلس الذهبي'::"text" NOT NULL,
    "timezone" "text" DEFAULT 'Africa/Cairo'::"text" NOT NULL,
    "daily_start" time without time zone DEFAULT '19:00:00'::time without time zone NOT NULL,
    "daily_end" time without time zone DEFAULT '20:00:00'::time without time zone NOT NULL,
    "allowed_days" integer[] DEFAULT ARRAY[6, 0, 1, 2, 3, 4] NOT NULL,
    "questions_per_day" integer DEFAULT 5 NOT NULL,
    "points_per_question" integer DEFAULT 10 NOT NULL,
    "weekly_thresholds" integer[] DEFAULT ARRAY[200, 230, 260, 280] NOT NULL,
    "weekly_seconds" integer[] DEFAULT ARRAY[20, 15, 10, 5] NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "golden_league_seconds_valid" CHECK ((("cardinality"("weekly_seconds") = 4) AND (("weekly_seconds"[1] >= 1) AND ("weekly_seconds"[1] <= 60)) AND (("weekly_seconds"[2] >= 1) AND ("weekly_seconds"[2] <= 60)) AND (("weekly_seconds"[3] >= 1) AND ("weekly_seconds"[3] <= 60)) AND (("weekly_seconds"[4] >= 1) AND ("weekly_seconds"[4] <= 60)))),
    CONSTRAINT "golden_league_settings_id_check" CHECK (("id" = 1)),
    CONSTRAINT "golden_league_settings_points_per_question_check" CHECK (("points_per_question" = 10)),
    CONSTRAINT "golden_league_settings_questions_per_day_check" CHECK (("questions_per_day" = 5)),
    CONSTRAINT "golden_league_thresholds_valid" CHECK ((("cardinality"("weekly_thresholds") = 4) AND ("weekly_thresholds"[1] >= 0) AND ("weekly_thresholds"[1] <= 300) AND ("weekly_thresholds"[2] >= 0) AND ("weekly_thresholds"[2] <= 300) AND ("weekly_thresholds"[3] >= 0) AND ("weekly_thresholds"[3] <= 300) AND ("weekly_thresholds"[4] >= 0) AND ("weekly_thresholds"[4] <= 300)))
);


ALTER TABLE "public"."golden_league_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."grades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text",
    "subject_id" "uuid",
    "grade_1" numeric,
    "grade_2" numeric,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "grade_1_source" "text",
    "grade_2_source" "text",
    "grade_1_note" "text",
    "grade_2_note" "text"
);


ALTER TABLE "public"."grades" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lead_followups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lead_id" "uuid",
    "note" "text",
    "next_followup_date" "date",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."lead_followups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."leads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text",
    "guardian_phone" "text",
    "branch" "text",
    "program_id" "text",
    "program" "text",
    "system_name" "text",
    "type" "text" DEFAULT 'استفسار'::"text",
    "notes" "text",
    "status" "text" DEFAULT 'جديد'::"text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source" "text",
    "campaign_id" "uuid",
    "next_followup_date" "date"
);


ALTER TABLE "public"."leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lecture_attendance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lecture_id" "uuid",
    "student_id" "text" NOT NULL,
    "status" "text" DEFAULT 'حاضر'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."lecture_attendance" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lectures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "lecturer" "text",
    "subject_name" "text",
    "program" "text",
    "lecture_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."lectures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."marketing_campaigns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "channel" "text",
    "branch" "text",
    "start_date" "date",
    "end_date" "date",
    "budget" numeric DEFAULT 0,
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."marketing_campaigns" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notification_receipts" (
    "notification_id" "uuid" NOT NULL,
    "student_id" "text" NOT NULL,
    "portal_type" "text" NOT NULL,
    "read_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notification_receipts_portal_type_check" CHECK (("portal_type" = ANY (ARRAY['student'::"text", 'parent'::"text"])))
);


ALTER TABLE "public"."notification_receipts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "notification_type" "text" DEFAULT 'general'::"text" NOT NULL,
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "audience" "text" DEFAULT 'all'::"text" NOT NULL,
    "student_id" "text",
    "branch" "text",
    "program" "text",
    "is_published" boolean DEFAULT false NOT NULL,
    "published_at" timestamp with time zone,
    "scheduled_for" timestamp with time zone,
    "expires_at" timestamp with time zone,
    "created_by" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "show_on_login" boolean DEFAULT false NOT NULL,
    CONSTRAINT "notifications_audience_check" CHECK (("audience" = ANY (ARRAY['all'::"text", 'branch'::"text", 'program'::"text", 'student'::"text", 'parent'::"text", 'staff'::"text"]))),
    CONSTRAINT "notifications_body_check" CHECK ((("length"("btrim"("body")) >= 1) AND ("length"("btrim"("body")) <= 5000))),
    CONSTRAINT "notifications_check" CHECK ((("expires_at" IS NULL) OR ("scheduled_for" IS NULL) OR ("expires_at" > "scheduled_for"))),
    CONSTRAINT "notifications_notification_type_check" CHECK (("notification_type" = ANY (ARRAY['general'::"text", 'academic'::"text", 'attendance'::"text", 'payments'::"text", 'exam'::"text", 'competition'::"text", 'request'::"text", 'system'::"text"]))),
    CONSTRAINT "notifications_priority_check" CHECK (("priority" = ANY (ARRAY['low'::"text", 'normal'::"text", 'high'::"text", 'urgent'::"text"]))),
    CONSTRAINT "notifications_title_check" CHECK ((("length"("btrim"("title")) >= 1) AND ("length"("btrim"("title")) <= 180)))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text",
    "payment_type" "text" NOT NULL,
    "label" "text",
    "amount" numeric DEFAULT 0 NOT NULL,
    "due_date" "text",
    "paid" boolean DEFAULT false,
    "paid_date" "text",
    "applicable" boolean DEFAULT true,
    "is_discount" boolean DEFAULT false,
    "late_fee_amount" numeric DEFAULT 50,
    "late_fee_paid" boolean DEFAULT false,
    "late_fee_exempted" boolean DEFAULT false,
    "exemption_reason" "text",
    "notes" "text",
    "created_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "eng_total_grade" numeric,
    "eng_student_grade" numeric,
    "eng_exam_result" "text",
    "last_reminder_sent" "date"
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."procedures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text",
    "type" "text" NOT NULL,
    "reference_number" "text",
    "date" "text",
    "details" "text",
    "result" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."procedures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."programs" (
    "id" "text" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "duration" "text",
    "fees" numeric,
    "advance" numeric,
    "systems" "jsonb" DEFAULT '[]'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "deposit" numeric,
    "system" "text",
    "notes" "text"
);


ALTER TABLE "public"."programs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quiz_answers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "quiz_date" "date" NOT NULL,
    "student_id" "text" NOT NULL,
    "question_id" "uuid" NOT NULL,
    "selected_option" "text",
    "is_correct" boolean,
    "points_earned" integer DEFAULT 0,
    "answered_at" timestamp with time zone DEFAULT "now"(),
    "face_verification_token" "uuid"
);


ALTER TABLE "public"."quiz_answers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quiz_bank_questions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "question" "text" NOT NULL,
    "option_a" "text" NOT NULL,
    "option_b" "text" NOT NULL,
    "option_c" "text" NOT NULL,
    "option_d" "text" NOT NULL,
    "correct_option" "text" NOT NULL,
    "category" "text",
    "points" integer DEFAULT 10,
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "quiz_bank_questions_correct_option_check" CHECK (("correct_option" = ANY (ARRAY['a'::"text", 'b'::"text", 'c'::"text", 'd'::"text"])))
);


ALTER TABLE "public"."quiz_bank_questions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quiz_daily_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "quiz_date" "date" NOT NULL,
    "question_ids" "jsonb" NOT NULL,
    "activated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."quiz_daily_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quiz_settings" (
    "id" integer DEFAULT 1 NOT NULL,
    "daily_time" time without time zone DEFAULT '19:00:00'::time without time zone,
    "questions_per_day" integer DEFAULT 5,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "quiz_settings_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."quiz_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quiz_weekly_scores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "student_name" "text",
    "week_start" "date" NOT NULL,
    "total_points" integer DEFAULT 0,
    "correct_count" integer DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."quiz_weekly_scores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reservations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text",
    "parent_phone" "text",
    "program" "text",
    "branch" "text",
    "notes" "text",
    "status" "text" DEFAULT 'حجز'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."reservations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."schedule_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "day" "text" NOT NULL,
    "day_order" integer,
    "start_time" "text" NOT NULL,
    "end_time" "text",
    "program_name" "text",
    "program_id" "text",
    "system_name" "text",
    "subject_name" "text",
    "branch" "text" NOT NULL,
    "trainer" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "trainer_code" "text",
    "program_combos" "jsonb" DEFAULT '[]'::"jsonb",
    "session_date" "date"
);


ALTER TABLE "public"."schedule_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."session_log" (
    "id" bigint NOT NULL,
    "user_id" "uuid",
    "username" "text",
    "login_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "logout_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."session_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."session_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."session_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."session_log_id_seq" OWNED BY "public"."session_log"."id";



CREATE TABLE IF NOT EXISTS "public"."student_achievements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "achievement_type" "text" DEFAULT 'general'::"text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "achievement_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "text",
    "points" integer DEFAULT 0 NOT NULL,
    "activity_points" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "student_achievements_activity_points_check" CHECK ((("activity_points" >= 0) AND ("activity_points" <= 100))),
    CONSTRAINT "student_achievements_points_check" CHECK ((("points" >= 0) AND ("points" <= 100)))
);


ALTER TABLE "public"."student_achievements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_ai_access" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "access_type" "text" NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "order_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "student_ai_access_access_type_check" CHECK (("access_type" = ANY (ARRAY['trial'::"text", 'subscription'::"text"]))),
    CONSTRAINT "student_ai_access_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'expired'::"text", 'revoked'::"text"])))
);


ALTER TABLE "public"."student_ai_access" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_ai_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "plan_code" "text" DEFAULT 'student_ai_monthly'::"text" NOT NULL,
    "amount" numeric(10,2) DEFAULT 100 NOT NULL,
    "status" "text" DEFAULT 'pending_payment'::"text" NOT NULL,
    "payment_method" "text" DEFAULT 'orange_wallet'::"text" NOT NULL,
    "payment_reference" "text",
    "payment_proof_path" "text",
    "order_code" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "reviewed_reason" "text",
    "hidden_from_student" boolean DEFAULT false NOT NULL,
    CONSTRAINT "student_ai_orders_status_check" CHECK (("status" = ANY (ARRAY['pending_payment'::"text", 'payment_submitted'::"text", 'approved'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."student_ai_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_ai_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" DEFAULT 'student_ai_monthly'::"text" NOT NULL,
    "title" "text" DEFAULT 'المساعد الذكي'::"text" NOT NULL,
    "price" numeric(10,2) DEFAULT 100 NOT NULL,
    "monthly_minutes" integer DEFAULT 120 NOT NULL,
    "trial_hours" integer DEFAULT 24 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payment_provider" "text",
    "payment_wallet_number" "text"
);


ALTER TABLE "public"."student_ai_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_ai_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "access_id" "uuid",
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_heartbeat_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."student_ai_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_ai_usage_daily" (
    "student_id" "text" NOT NULL,
    "usage_date" "date" NOT NULL,
    "used_seconds" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "student_ai_usage_daily_used_seconds_check" CHECK (("used_seconds" >= 0))
);


ALTER TABLE "public"."student_ai_usage_daily" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_device_auth_attempts" (
    "id" bigint NOT NULL,
    "credential_hash" "text" NOT NULL,
    "device_hash" "text",
    "succeeded" boolean DEFAULT false NOT NULL,
    "reason" "text",
    "attempted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."student_device_auth_attempts" OWNER TO "postgres";


ALTER TABLE "public"."student_device_auth_attempts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."student_device_auth_attempts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."student_device_bindings" (
    "student_id" "text" NOT NULL,
    "device_token_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."student_device_bindings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_disciplinary_actions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "action_type" "text" NOT NULL,
    "action_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "decision_number" "text",
    "reason" "text",
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "student_disciplinary_actions_action_type_check" CHECK (("action_type" = ANY (ARRAY['dismissal'::"text", 'grievance_restore'::"text", 'final_dismissal'::"text"])))
);


ALTER TABLE "public"."student_disciplinary_actions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_evaluations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "session_id" "uuid",
    "date" "date" NOT NULL,
    "subject_name" "text",
    "trainer" "text",
    "rating" "text" NOT NULL,
    "note" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "student_evaluations_rating_check" CHECK (("rating" = ANY (ARRAY['ممتاز'::"text", 'يحتاج متابعة'::"text"])))
);


ALTER TABLE "public"."student_evaluations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_files" (
    "id" bigint NOT NULL,
    "student_id" "text",
    "file_name" "text",
    "file_url" "text",
    "file_path" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."student_files" OWNER TO "postgres";


ALTER TABLE "public"."student_files" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."student_files_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."student_passkey_challenges" (
    "student_id" "text" NOT NULL,
    "challenge_type" "text" NOT NULL,
    "challenge" "text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "student_passkey_challenges_challenge_type_check" CHECK (("challenge_type" = ANY (ARRAY['registration'::"text", 'authentication'::"text"])))
);


ALTER TABLE "public"."student_passkey_challenges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_passkey_sessions" (
    "token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "device_token_hash" "text" NOT NULL,
    "verified_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:15:00'::interval) NOT NULL
);


ALTER TABLE "public"."student_passkey_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_passkeys" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "credential_id" "text" NOT NULL,
    "public_key_b64" "text" NOT NULL,
    "webauthn_user_id" "text" NOT NULL,
    "counter" bigint DEFAULT 0 NOT NULL,
    "device_type" "text",
    "backed_up" boolean DEFAULT false NOT NULL,
    "transports" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_used_at" timestamp with time zone
);


ALTER TABLE "public"."student_passkeys" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_portal_access_logs" (
    "id" bigint NOT NULL,
    "student_id" "text",
    "enrollment_number" "text",
    "student_name" "text",
    "phone" "text",
    "competition_type" "text" DEFAULT 'student_portal'::"text" NOT NULL,
    "competition_id" "text",
    "event_type" "text" DEFAULT 'face_verify'::"text" NOT NULL,
    "outcome" "text" NOT NULL,
    "reason" "text",
    "distance" double precision,
    "threshold" double precision,
    "model_version" "text",
    "provider" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."student_portal_access_logs" OWNER TO "postgres";


ALTER TABLE "public"."student_portal_access_logs" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."student_portal_access_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."student_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "requester_type" "text" NOT NULL,
    "requester_name" "text",
    "requester_phone" "text" NOT NULL,
    "request_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "priority" "text" DEFAULT 'normal'::"text" NOT NULL,
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "branch" "text",
    "program" "text",
    "admin_response" "text",
    "assigned_to" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "student_hidden_at" timestamp with time zone,
    CONSTRAINT "student_requests_description_check" CHECK ((("length"("btrim"("description")) >= 5) AND ("length"("btrim"("description")) <= 3000))),
    CONSTRAINT "student_requests_priority_check" CHECK (("priority" = ANY (ARRAY['normal'::"text", 'high'::"text", 'urgent'::"text"]))),
    CONSTRAINT "student_requests_request_type_check" CHECK (("request_type" = ANY (ARRAY['complaint'::"text", 'request'::"text", 'academic'::"text", 'financial'::"text", 'technical'::"text", 'other'::"text"]))),
    CONSTRAINT "student_requests_requester_type_check" CHECK (("requester_type" = ANY (ARRAY['student'::"text", 'parent'::"text"]))),
    CONSTRAINT "student_requests_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'in_progress'::"text", 'waiting_student'::"text", 'resolved'::"text", 'closed'::"text"]))),
    CONSTRAINT "student_requests_title_check" CHECK ((("length"("btrim"("title")) >= 3) AND ("length"("btrim"("title")) <= 150)))
);


ALTER TABLE "public"."student_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."study_summaries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "subject_name" "text" DEFAULT ''::"text" NOT NULL,
    "price" numeric(10,2) DEFAULT 0 NOT NULL,
    "validity_days" integer DEFAULT 30 NOT NULL,
    "is_published" boolean DEFAULT false NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source_pdf_path" "text",
    "ai_generation_status" "text" DEFAULT 'not_started'::"text" NOT NULL,
    "ai_generation_error" "text",
    "generated_question_count" integer DEFAULT 0 NOT NULL,
    "target_branch" "text",
    "target_system" "text",
    "target_batch" "text",
    "target_all" boolean DEFAULT true NOT NULL,
    "material_text" "text",
    "published_at" timestamp with time zone,
    "is_approved" boolean DEFAULT false NOT NULL,
    "approved_at" timestamp with time zone,
    "approved_by" "uuid",
    "available_from" timestamp with time zone,
    "available_until" timestamp with time zone,
    "enabled_batches" "jsonb" DEFAULT '[1, 2]'::"jsonb" NOT NULL,
    "payment_provider" "text",
    "payment_wallet_number" "text",
    "enabled_question_types" "jsonb" DEFAULT '["mcq", "true_false", "essay"]'::"jsonb" NOT NULL,
    CONSTRAINT "study_summaries_ai_generation_status_check" CHECK (("ai_generation_status" = ANY (ARRAY['not_started'::"text", 'processing'::"text", 'ready'::"text", 'failed'::"text"]))),
    CONSTRAINT "study_summaries_enabled_question_types_check" CHECK ((("jsonb_typeof"("enabled_question_types") = 'array'::"text") AND ("enabled_question_types" <@ '["mcq", "true_false", "essay"]'::"jsonb"))),
    CONSTRAINT "study_summaries_payment_provider_check" CHECK ((("payment_provider" IS NULL) OR (("length"("btrim"("payment_provider")) >= 2) AND ("length"("btrim"("payment_provider")) <= 80)))),
    CONSTRAINT "study_summaries_payment_wallet_number_check" CHECK ((("payment_wallet_number" IS NULL) OR (("length"("btrim"("payment_wallet_number")) >= 6) AND ("length"("btrim"("payment_wallet_number")) <= 40)))),
    CONSTRAINT "study_summaries_price_check" CHECK (("price" >= (0)::numeric)),
    CONSTRAINT "study_summaries_title_check" CHECK ((("length"("btrim"("title")) >= 2) AND ("length"("btrim"("title")) <= 180))),
    CONSTRAINT "study_summaries_validity_days_check" CHECK ((("validity_days" >= 1) AND ("validity_days" <= 3650)))
);


ALTER TABLE "public"."study_summaries" OWNER TO "postgres";


COMMENT ON COLUMN "public"."study_summaries"."enabled_batches" IS 'Admin-selected visible question batches; batches are combined into one student summary';



CREATE TABLE IF NOT EXISTS "public"."study_summary_activity" (
    "id" bigint NOT NULL,
    "student_id" "text",
    "summary_id" "uuid",
    "order_id" "uuid",
    "event_type" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "study_summary_activity_event_type_check" CHECK (("event_type" = ANY (ARRAY['list'::"text", 'open'::"text", 'question'::"text", 'order_created'::"text", 'access_denied'::"text", 'payment_reference_submitted'::"text", 'access_granted'::"text"])))
);


ALTER TABLE "public"."study_summary_activity" OWNER TO "postgres";


ALTER TABLE "public"."study_summary_activity" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."study_summary_activity_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."study_summary_entitlements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "summary_id" "uuid" NOT NULL,
    "order_id" "uuid",
    "starts_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "revoked_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."study_summary_entitlements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."study_summary_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "student_id" "text" NOT NULL,
    "summary_id" "uuid" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "status" "text" DEFAULT 'pending_payment'::"text" NOT NULL,
    "payment_method" "text" DEFAULT 'not_configured'::"text" NOT NULL,
    "payment_reference" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "reviewed_reason" "text",
    "payment_number" "text",
    "order_code" "text",
    "expires_at" timestamp with time zone,
    "access_hours" integer,
    "payment_proof_path" "text",
    "hidden_from_student" boolean DEFAULT false NOT NULL,
    "admin_deleted_at" timestamp with time zone,
    CONSTRAINT "study_summary_orders_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "study_summary_orders_status_check" CHECK (("status" = ANY (ARRAY['pending_payment'::"text", 'paid'::"text", 'cancelled'::"text", 'rejected'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."study_summary_orders" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."study_summary_package_items" (
    "package_id" "uuid" NOT NULL,
    "summary_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."study_summary_package_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."study_summary_packages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "price" numeric DEFAULT 0 NOT NULL,
    "validity_days" integer DEFAULT 2 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "study_summary_packages_name_check" CHECK ((("length"("btrim"("name")) >= 2) AND ("length"("btrim"("name")) <= 180))),
    CONSTRAINT "study_summary_packages_price_check" CHECK (("price" >= (0)::numeric)),
    CONSTRAINT "study_summary_packages_validity_days_check" CHECK ((("validity_days" >= 1) AND ("validity_days" <= 3650)))
);


ALTER TABLE "public"."study_summary_packages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."study_summary_questions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "summary_id" "uuid" NOT NULL,
    "question_text" "text" NOT NULL,
    "answer_text" "text" NOT NULL,
    "explanation" "text" DEFAULT ''::"text" NOT NULL,
    "order_num" integer DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "question_type" "text" DEFAULT 'mcq'::"text" NOT NULL,
    "options" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "ai_generated" boolean DEFAULT false NOT NULL,
    "source_reference" "text",
    "is_approved" boolean DEFAULT false NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "is_selected" boolean DEFAULT true NOT NULL,
    "batch_no" integer DEFAULT 1 NOT NULL,
    "source_page" integer,
    CONSTRAINT "study_summary_questions_answer_text_check" CHECK ((("length"("btrim"("answer_text")) >= 1) AND ("length"("btrim"("answer_text")) <= 20000))),
    CONSTRAINT "study_summary_questions_order_num_check" CHECK (("order_num" > 0)),
    CONSTRAINT "study_summary_questions_question_text_check" CHECK ((("length"("btrim"("question_text")) >= 1) AND ("length"("btrim"("question_text")) <= 12000))),
    CONSTRAINT "study_summary_questions_question_type_check" CHECK (("question_type" = ANY (ARRAY['mcq'::"text", 'true_false'::"text", 'essay'::"text"])))
);


ALTER TABLE "public"."study_summary_questions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."study_summary_questions"."batch_no" IS 'Independent question batch: 1 or 2';



COMMENT ON COLUMN "public"."study_summary_questions"."source_page" IS 'Page number in source PDF for admin review';



CREATE TABLE IF NOT EXISTS "public"."subjects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "max_grade_1" numeric DEFAULT 100,
    "max_grade_2" numeric DEFAULT 100,
    "min_pass" numeric DEFAULT 50,
    "order_num" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "pass_grade_1" numeric DEFAULT 25,
    "pass_grade_2" numeric DEFAULT 25
);


ALTER TABLE "public"."subjects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_settings" (
    "key" "text" NOT NULL,
    "value" "text"
);


ALTER TABLE "public"."system_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "details" "text",
    "due_date" "date",
    "branch" "text",
    "done" boolean DEFAULT false,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "due_time" "text",
    "dismissed" boolean DEFAULT false,
    "link_type" "text",
    "link_value" "text"
);


ALTER TABLE "public"."tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "username" "text" NOT NULL,
    "password" "text" NOT NULL,
    "full_name" "text",
    "role" "text" DEFAULT 'employee'::"text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "last_login" timestamp with time zone,
    "branch" "text" DEFAULT 'الفرعين'::"text",
    "full_control" boolean DEFAULT false
);


ALTER TABLE "public"."users" OWNER TO "postgres";


ALTER TABLE ONLY "public"."activity_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."activity_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."daily_revenue" ALTER COLUMN "serial_no" SET DEFAULT "nextval"('"public"."daily_revenue_serial_no_seq"'::"regclass");



ALTER TABLE ONLY "public"."session_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."session_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."activity_log"
    ADD CONSTRAINT "activity_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ai_conversations"
    ADD CONSTRAINT "ai_conversations_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."alumni_placements"
    ADD CONSTRAINT "alumni_placements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."andalus_ai_tasks"
    ADD CONSTRAINT "andalus_ai_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."attendance_session_exclusions"
    ADD CONSTRAINT "attendance_session_exclusions_pkey" PRIMARY KEY ("session_id", "student_id");



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_student_session_date_unique" UNIQUE ("student_id", "session_id", "date");



ALTER TABLE ONLY "public"."cash_register_logs"
    ADD CONSTRAINT "cash_register_logs_branch_log_date_key" UNIQUE ("branch", "log_date");



ALTER TABLE ONLY "public"."cash_register_logs"
    ADD CONSTRAINT "cash_register_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."certificate_records"
    ADD CONSTRAINT "certificate_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."certificate_records"
    ADD CONSTRAINT "certificate_records_serial_key" UNIQUE ("serial");



ALTER TABLE ONLY "public"."certificate_templates"
    ADD CONSTRAINT "certificate_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."competition_entries"
    ADD CONSTRAINT "competition_entries_competition_id_student_id_key" UNIQUE ("competition_id", "student_id");



ALTER TABLE ONLY "public"."competition_entries"
    ADD CONSTRAINT "competition_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."competition_face_enrollments"
    ADD CONSTRAINT "competition_face_enrollments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."competition_face_enrollments"
    ADD CONSTRAINT "competition_face_enrollments_provider_provider_subject_id_key" UNIQUE ("provider", "provider_subject_id");



ALTER TABLE ONLY "public"."competition_face_enrollments"
    ADD CONSTRAINT "competition_face_enrollments_student_id_provider_key" UNIQUE ("student_id", "provider");



ALTER TABLE ONLY "public"."competition_face_verified_sessions"
    ADD CONSTRAINT "competition_face_verified_sessions_pkey" PRIMARY KEY ("token");



ALTER TABLE ONLY "public"."competition_security_logs"
    ADD CONSTRAINT "competition_security_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."competitions"
    ADD CONSTRAINT "competitions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."contact_log"
    ADD CONSTRAINT "contact_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_revenue"
    ADD CONSTRAINT "daily_revenue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_activity_log"
    ADD CONSTRAINT "employee_activity_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exam_attempts"
    ADD CONSTRAINT "exam_attempts_exam_id_student_id_key" UNIQUE ("exam_id", "student_id");



ALTER TABLE ONLY "public"."exam_attempts"
    ADD CONSTRAINT "exam_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exam_questions"
    ADD CONSTRAINT "exam_questions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."exams"
    ADD CONSTRAINT "exams_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gallery_albums"
    ADD CONSTRAINT "gallery_albums_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gallery_photos"
    ADD CONSTRAINT "gallery_photos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."golden_league_question_starts"
    ADD CONSTRAINT "golden_league_question_starts_pkey" PRIMARY KEY ("student_id", "quiz_date", "question_id");



ALTER TABLE ONLY "public"."golden_league_settings"
    ADD CONSTRAINT "golden_league_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grades"
    ADD CONSTRAINT "grades_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grades"
    ADD CONSTRAINT "grades_student_id_subject_id_key" UNIQUE ("student_id", "subject_id");



ALTER TABLE ONLY "public"."lead_followups"
    ADD CONSTRAINT "lead_followups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lecture_attendance"
    ADD CONSTRAINT "lecture_attendance_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."lectures"
    ADD CONSTRAINT "lectures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."marketing_campaigns"
    ADD CONSTRAINT "marketing_campaigns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notification_receipts"
    ADD CONSTRAINT "notification_receipts_pkey" PRIMARY KEY ("notification_id", "student_id", "portal_type");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_student_type_unique" UNIQUE ("student_id", "payment_type");



ALTER TABLE ONLY "public"."procedures"
    ADD CONSTRAINT "procedures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."programs"
    ADD CONSTRAINT "programs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quiz_answers"
    ADD CONSTRAINT "quiz_answers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quiz_answers"
    ADD CONSTRAINT "quiz_answers_quiz_date_student_id_question_id_key" UNIQUE ("quiz_date", "student_id", "question_id");



ALTER TABLE ONLY "public"."quiz_bank_questions"
    ADD CONSTRAINT "quiz_bank_questions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quiz_daily_sessions"
    ADD CONSTRAINT "quiz_daily_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quiz_daily_sessions"
    ADD CONSTRAINT "quiz_daily_sessions_quiz_date_key" UNIQUE ("quiz_date");



ALTER TABLE ONLY "public"."quiz_settings"
    ADD CONSTRAINT "quiz_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quiz_weekly_scores"
    ADD CONSTRAINT "quiz_weekly_scores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quiz_weekly_scores"
    ADD CONSTRAINT "quiz_weekly_scores_student_id_week_start_key" UNIQUE ("student_id", "week_start");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."schedule_sessions"
    ADD CONSTRAINT "schedule_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."session_log"
    ADD CONSTRAINT "session_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_achievements"
    ADD CONSTRAINT "student_achievements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_ai_access"
    ADD CONSTRAINT "student_ai_access_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_ai_orders"
    ADD CONSTRAINT "student_ai_orders_order_code_key" UNIQUE ("order_code");



ALTER TABLE ONLY "public"."student_ai_orders"
    ADD CONSTRAINT "student_ai_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_ai_plans"
    ADD CONSTRAINT "student_ai_plans_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."student_ai_plans"
    ADD CONSTRAINT "student_ai_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_ai_sessions"
    ADD CONSTRAINT "student_ai_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_ai_usage_daily"
    ADD CONSTRAINT "student_ai_usage_daily_pkey" PRIMARY KEY ("student_id", "usage_date");



ALTER TABLE ONLY "public"."student_device_auth_attempts"
    ADD CONSTRAINT "student_device_auth_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_device_bindings"
    ADD CONSTRAINT "student_device_bindings_device_token_hash_key" UNIQUE ("device_token_hash");



ALTER TABLE ONLY "public"."student_device_bindings"
    ADD CONSTRAINT "student_device_bindings_pkey" PRIMARY KEY ("student_id");



ALTER TABLE ONLY "public"."student_disciplinary_actions"
    ADD CONSTRAINT "student_disciplinary_actions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_evaluations"
    ADD CONSTRAINT "student_evaluations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_evaluations"
    ADD CONSTRAINT "student_evaluations_student_id_session_id_date_key" UNIQUE ("student_id", "session_id", "date");



ALTER TABLE ONLY "public"."student_files"
    ADD CONSTRAINT "student_files_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_passkey_challenges"
    ADD CONSTRAINT "student_passkey_challenges_pkey" PRIMARY KEY ("student_id");



ALTER TABLE ONLY "public"."student_passkey_sessions"
    ADD CONSTRAINT "student_passkey_sessions_pkey" PRIMARY KEY ("token");



ALTER TABLE ONLY "public"."student_passkeys"
    ADD CONSTRAINT "student_passkeys_credential_id_key" UNIQUE ("credential_id");



ALTER TABLE ONLY "public"."student_passkeys"
    ADD CONSTRAINT "student_passkeys_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_passkeys"
    ADD CONSTRAINT "student_passkeys_student_user_unique" UNIQUE ("student_id", "webauthn_user_id");



ALTER TABLE ONLY "public"."student_portal_access_logs"
    ADD CONSTRAINT "student_portal_access_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."student_requests"
    ADD CONSTRAINT "student_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_summaries"
    ADD CONSTRAINT "study_summaries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_summary_activity"
    ADD CONSTRAINT "study_summary_activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_summary_entitlements"
    ADD CONSTRAINT "study_summary_entitlements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_summary_entitlements"
    ADD CONSTRAINT "study_summary_entitlements_student_id_summary_id_order_id_key" UNIQUE ("student_id", "summary_id", "order_id");



ALTER TABLE ONLY "public"."study_summary_orders"
    ADD CONSTRAINT "study_summary_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_summary_package_items"
    ADD CONSTRAINT "study_summary_package_items_pkey" PRIMARY KEY ("package_id", "summary_id");



ALTER TABLE ONLY "public"."study_summary_package_items"
    ADD CONSTRAINT "study_summary_package_items_summary_id_key" UNIQUE ("summary_id");



ALTER TABLE ONLY "public"."study_summary_packages"
    ADD CONSTRAINT "study_summary_packages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."study_summary_questions"
    ADD CONSTRAINT "study_summary_questions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subjects"
    ADD CONSTRAINT "subjects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_settings"
    ADD CONSTRAINT "system_settings_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."weekly_quiz_access_audit"
    ADD CONSTRAINT "weekly_quiz_access_audit_pkey" PRIMARY KEY ("id");



CREATE INDEX "andalus_ai_tasks_due_idx" ON "public"."andalus_ai_tasks" USING "btree" ("run_at") WHERE ("status" = 'scheduled'::"text");



CREATE INDEX "andalus_ai_tasks_status_idx" ON "public"."andalus_ai_tasks" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "competition_security_logs_created_at_idx" ON "public"."competition_security_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "competition_security_logs_enrollment_idx" ON "public"."competition_security_logs" USING "btree" ("enrollment_number", "created_at" DESC);



CREATE INDEX "competition_security_logs_ip_idx" ON "public"."competition_security_logs" USING "btree" ("ip_address", "created_at" DESC);



CREATE INDEX "employee_activity_log_actor_created_idx" ON "public"."employee_activity_log" USING "btree" ("actor_user_id", "created_at" DESC);



CREATE INDEX "employee_activity_log_created_idx" ON "public"."employee_activity_log" USING "btree" ("created_at" DESC);



CREATE INDEX "employee_activity_log_entity_idx" ON "public"."employee_activity_log" USING "btree" ("entity_table", "entity_id");



CREATE INDEX "golden_league_question_starts_question_id_idx" ON "public"."golden_league_question_starts" USING "btree" ("question_id");



CREATE INDEX "idx_activity_log_created" ON "public"."activity_log" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_activity_log_user" ON "public"."activity_log" USING "btree" ("user_id");



CREATE INDEX "idx_alumni_student_id" ON "public"."alumni_placements" USING "btree" ("student_id");



CREATE INDEX "idx_attendance_date" ON "public"."attendance" USING "btree" ("date");



CREATE INDEX "idx_attendance_session_id" ON "public"."attendance" USING "btree" ("session_id");



CREATE INDEX "idx_attendance_student_id" ON "public"."attendance" USING "btree" ("student_id");



CREATE INDEX "idx_contact_log_student" ON "public"."contact_log" USING "btree" ("student_id");



CREATE INDEX "idx_exam_attempts_exam" ON "public"."exam_attempts" USING "btree" ("exam_id");



CREATE INDEX "idx_exam_attempts_student" ON "public"."exam_attempts" USING "btree" ("student_id");



CREATE INDEX "idx_exam_questions_exam" ON "public"."exam_questions" USING "btree" ("exam_id");



CREATE INDEX "idx_exams_branch" ON "public"."exams" USING "btree" ("branch");



CREATE INDEX "idx_exams_subject" ON "public"."exams" USING "btree" ("subject_id");



CREATE INDEX "idx_expenses_branch" ON "public"."expenses" USING "btree" ("branch");



CREATE INDEX "idx_expenses_branch_date" ON "public"."expenses" USING "btree" ("branch", "expense_date" DESC);



CREATE INDEX "idx_expenses_date" ON "public"."expenses" USING "btree" ("expense_date" DESC);



CREATE INDEX "idx_face_verified_sessions_student_expiry" ON "public"."competition_face_verified_sessions" USING "btree" ("student_id", "expires_at" DESC);



CREATE INDEX "idx_fk_attendance_recorded_by" ON "public"."attendance" USING "btree" ("recorded_by");



CREATE INDEX "idx_fk_attendance_session_exclusions_student_id" ON "public"."attendance_session_exclusions" USING "btree" ("student_id");



CREATE INDEX "idx_fk_competition_entries_student_id" ON "public"."competition_entries" USING "btree" ("student_id");



CREATE INDEX "idx_fk_expenses_created_by" ON "public"."expenses" USING "btree" ("created_by");



CREATE INDEX "idx_fk_gallery_photos_album_id" ON "public"."gallery_photos" USING "btree" ("album_id");



CREATE INDEX "idx_fk_grades_subject_id" ON "public"."grades" USING "btree" ("subject_id");



CREATE INDEX "idx_fk_lead_followups_lead_id" ON "public"."lead_followups" USING "btree" ("lead_id");



CREATE INDEX "idx_fk_leads_campaign_id" ON "public"."leads" USING "btree" ("campaign_id");



CREATE INDEX "idx_fk_leads_created_by" ON "public"."leads" USING "btree" ("created_by");



CREATE INDEX "idx_fk_leads_program_id" ON "public"."leads" USING "btree" ("program_id");



CREATE INDEX "idx_fk_lecture_attendance_lecture_id" ON "public"."lecture_attendance" USING "btree" ("lecture_id");



CREATE INDEX "idx_fk_notification_receipts_student_id" ON "public"."notification_receipts" USING "btree" ("student_id");



CREATE INDEX "idx_fk_notifications_created_by" ON "public"."notifications" USING "btree" ("created_by");



CREATE INDEX "idx_fk_payments_created_by" ON "public"."payments" USING "btree" ("created_by");



CREATE INDEX "idx_fk_procedures_created_by" ON "public"."procedures" USING "btree" ("created_by");



CREATE INDEX "idx_fk_student_disciplinary_actions_created_by" ON "public"."student_disciplinary_actions" USING "btree" ("created_by");



CREATE INDEX "idx_fk_student_evaluations_session_id" ON "public"."student_evaluations" USING "btree" ("session_id");



CREATE INDEX "idx_fk_students_created_by" ON "public"."students" USING "btree" ("created_by");



CREATE INDEX "idx_fk_students_dismissed_by" ON "public"."students" USING "btree" ("dismissed_by");



CREATE INDEX "idx_fk_students_referred_by" ON "public"."students" USING "btree" ("referred_by");



CREATE INDEX "idx_fk_study_summaries_approved_by" ON "public"."study_summaries" USING "btree" ("approved_by");



CREATE INDEX "idx_fk_study_summaries_created_by" ON "public"."study_summaries" USING "btree" ("created_by");



CREATE INDEX "idx_fk_study_summary_activity_order_id" ON "public"."study_summary_activity" USING "btree" ("order_id");



CREATE INDEX "idx_fk_study_summary_activity_student_id" ON "public"."study_summary_activity" USING "btree" ("student_id");



CREATE INDEX "idx_fk_study_summary_activity_summary_id" ON "public"."study_summary_activity" USING "btree" ("summary_id");



CREATE INDEX "idx_fk_study_summary_entitlements_order_id" ON "public"."study_summary_entitlements" USING "btree" ("order_id");



CREATE INDEX "idx_fk_study_summary_entitlements_summary_id" ON "public"."study_summary_entitlements" USING "btree" ("summary_id");



CREATE INDEX "idx_fk_study_summary_orders_reviewed_by" ON "public"."study_summary_orders" USING "btree" ("reviewed_by");



CREATE INDEX "idx_fk_study_summary_orders_summary_id" ON "public"."study_summary_orders" USING "btree" ("summary_id");



CREATE INDEX "idx_grades_student_id" ON "public"."grades" USING "btree" ("student_id");



CREATE INDEX "idx_leads_branch" ON "public"."leads" USING "btree" ("branch");



CREATE INDEX "idx_leads_source" ON "public"."leads" USING "btree" ("source");



CREATE INDEX "idx_leads_status" ON "public"."leads" USING "btree" ("status");



CREATE INDEX "idx_payments_student_id" ON "public"."payments" USING "btree" ("student_id");



CREATE INDEX "idx_payments_type" ON "public"."payments" USING "btree" ("payment_type");



CREATE INDEX "idx_procedures_student_id" ON "public"."procedures" USING "btree" ("student_id");



CREATE INDEX "idx_schedule_sessions_branch" ON "public"."schedule_sessions" USING "btree" ("branch");



CREATE INDEX "idx_schedule_sessions_date" ON "public"."schedule_sessions" USING "btree" ("session_date");



CREATE INDEX "idx_schedule_sessions_trainer_code" ON "public"."schedule_sessions" USING "btree" ("trainer_code");



CREATE INDEX "idx_session_log_login" ON "public"."session_log" USING "btree" ("login_at" DESC);



CREATE INDEX "idx_session_log_user" ON "public"."session_log" USING "btree" ("user_id");



CREATE INDEX "idx_student_achievements_student_date" ON "public"."student_achievements" USING "btree" ("student_id", "achievement_date" DESC, "created_at" DESC);



CREATE INDEX "idx_student_ai_access_student_active" ON "public"."student_ai_access" USING "btree" ("student_id", "status", "expires_at");



CREATE INDEX "idx_student_ai_orders_student_status" ON "public"."student_ai_orders" USING "btree" ("student_id", "status", "created_at" DESC);



CREATE INDEX "idx_student_ai_sessions_student_active" ON "public"."student_ai_sessions" USING "btree" ("student_id", "active", "last_heartbeat_at" DESC);



CREATE INDEX "idx_student_disciplinary_actions_student_id" ON "public"."student_disciplinary_actions" USING "btree" ("student_id", "action_date" DESC);



CREATE INDEX "idx_student_portal_access_logs_created_at" ON "public"."student_portal_access_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_student_portal_access_logs_outcome" ON "public"."student_portal_access_logs" USING "btree" ("outcome", "created_at" DESC);



CREATE INDEX "idx_student_portal_access_logs_student_id" ON "public"."student_portal_access_logs" USING "btree" ("student_id", "created_at" DESC);



CREATE INDEX "idx_students_branch" ON "public"."students" USING "btree" ("branch");



CREATE INDEX "idx_students_deleted_at" ON "public"."students" USING "btree" ("deleted_at");



CREATE INDEX "idx_students_national_id" ON "public"."students" USING "btree" ("national_id");



CREATE INDEX "idx_students_phone" ON "public"."students" USING "btree" ("phone");



CREATE INDEX "idx_students_program_id" ON "public"."students" USING "btree" ("program_id");



CREATE INDEX "idx_students_total_due" ON "public"."students" USING "btree" ("total_due");



CREATE INDEX "idx_study_summary_entitlements_student" ON "public"."study_summary_entitlements" USING "btree" ("student_id", "summary_id");



CREATE INDEX "idx_study_summary_orders_status" ON "public"."study_summary_orders" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "idx_study_summary_questions_summary_type" ON "public"."study_summary_questions" USING "btree" ("summary_id", "question_type");



CREATE INDEX "idx_tasks_due" ON "public"."tasks" USING "btree" ("due_date", "due_time");



CREATE INDEX "idx_user_profiles_role" ON "public"."user_profiles" USING "btree" ("role");



CREATE INDEX "idx_user_profiles_username" ON "public"."user_profiles" USING "btree" ("username");



CREATE INDEX "idx_weekly_quiz_access_audit_failure_code" ON "public"."weekly_quiz_access_audit" USING "btree" ("failure_code", "entered_at" DESC);



CREATE INDEX "idx_weekly_quiz_access_audit_outcome" ON "public"."weekly_quiz_access_audit" USING "btree" ("outcome", "entered_at" DESC);



CREATE INDEX "idx_weekly_quiz_access_audit_student_entered" ON "public"."weekly_quiz_access_audit" USING "btree" ("student_id", "entered_at" DESC);



CREATE INDEX "notifications_audience_branch_program_idx" ON "public"."notifications" USING "btree" ("audience", "branch", "program", "student_id", "created_at" DESC);



CREATE INDEX "notifications_publish_window_idx" ON "public"."notifications" USING "btree" ("is_published", "scheduled_for", "expires_at", "created_at" DESC);



CREATE INDEX "quiz_answers_student_date_golden_idx" ON "public"."quiz_answers" USING "btree" ("student_id", "quiz_date");



CREATE INDEX "quiz_weekly_scores_week_rank_golden_idx" ON "public"."quiz_weekly_scores" USING "btree" ("week_start", "total_points" DESC, "correct_count" DESC);



CREATE UNIQUE INDEX "student_ai_one_active_session_per_student" ON "public"."student_ai_sessions" USING "btree" ("student_id") WHERE ("active" = true);



CREATE UNIQUE INDEX "student_ai_one_trial_per_student" ON "public"."student_ai_access" USING "btree" ("student_id") WHERE ("access_type" = 'trial'::"text");



CREATE INDEX "student_device_auth_attempts_cleanup_idx" ON "public"."student_device_auth_attempts" USING "btree" ("attempted_at");



CREATE INDEX "student_device_auth_attempts_device_idx" ON "public"."student_device_auth_attempts" USING "btree" ("credential_hash", "device_hash", "attempted_at" DESC);



CREATE INDEX "student_device_auth_attempts_recent_idx" ON "public"."student_device_auth_attempts" USING "btree" ("credential_hash", "attempted_at" DESC);



CREATE INDEX "student_passkey_sessions_student_idx" ON "public"."student_passkey_sessions" USING "btree" ("student_id", "expires_at");



CREATE INDEX "student_passkeys_student_id_idx" ON "public"."student_passkeys" USING "btree" ("student_id");



CREATE INDEX "student_requests_status_created_idx" ON "public"."student_requests" USING "btree" ("status", "created_at" DESC);



CREATE INDEX "student_requests_student_created_idx" ON "public"."student_requests" USING "btree" ("student_id", "created_at" DESC);



CREATE INDEX "study_summary_activity_created_idx" ON "public"."study_summary_activity" USING "btree" ("created_at" DESC);



CREATE INDEX "study_summary_entitlements_active_idx" ON "public"."study_summary_entitlements" USING "btree" ("student_id", "summary_id", "expires_at" DESC) WHERE ("revoked_at" IS NULL);



CREATE UNIQUE INDEX "study_summary_orders_order_code_uidx" ON "public"."study_summary_orders" USING "btree" ("order_code");



CREATE UNIQUE INDEX "study_summary_orders_order_code_unique" ON "public"."study_summary_orders" USING "btree" ("order_code") WHERE (("order_code" IS NOT NULL) AND ("btrim"("order_code") <> ''::"text"));



CREATE INDEX "study_summary_orders_pending_expiry_idx" ON "public"."study_summary_orders" USING "btree" ("status", "expires_at");



CREATE INDEX "study_summary_orders_student_idx" ON "public"."study_summary_orders" USING "btree" ("student_id", "created_at" DESC);



CREATE INDEX "study_summary_questions_order_idx" ON "public"."study_summary_questions" USING "btree" ("summary_id", "order_num", "id");



CREATE INDEX "weekly_quiz_access_audit_entered_at_idx" ON "public"."weekly_quiz_access_audit" USING "btree" ("entered_at" DESC);



CREATE INDEX "weekly_quiz_access_audit_student_id_idx" ON "public"."weekly_quiz_access_audit" USING "btree" ("student_id");



CREATE OR REPLACE TRIGGER "trg_auto_hide_expelled_student" AFTER INSERT OR UPDATE OF "type" ON "public"."procedures" FOR EACH ROW EXECUTE FUNCTION "public"."auto_hide_expelled_student"();



CREATE OR REPLACE TRIGGER "trg_award_attendance_milestone" AFTER INSERT OR UPDATE OF "status" ON "public"."attendance" FOR EACH ROW WHEN (("new"."status" = 'حاضر'::"text")) EXECUTE FUNCTION "public"."award_attendance_milestone"();



CREATE OR REPLACE TRIGGER "trg_cancel_pending_summary_orders_after_access" AFTER INSERT OR UPDATE OF "revoked_at", "starts_at", "expires_at" ON "public"."study_summary_entitlements" FOR EACH ROW EXECUTE FUNCTION "public"."cancel_pending_summary_orders_after_access"();



CREATE OR REPLACE TRIGGER "trg_daily_revenue_student_finance" AFTER INSERT ON "public"."daily_revenue" FOR EACH ROW EXECUTE FUNCTION "public"."sync_daily_revenue_to_student_finance"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."activity_log" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."ai_conversations" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."alumni_placements" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."andalus_ai_tasks" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."attendance" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."attendance_session_exclusions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."cash_register_logs" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."certificate_records" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."certificate_templates" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."competition_entries" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."competition_face_enrollments" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."competition_face_verified_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."competition_security_logs" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."competitions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."contact_log" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."daily_revenue" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."exam_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."exam_questions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."exams" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."expenses" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."gallery_albums" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."gallery_photos" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."golden_league_question_starts" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."golden_league_settings" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."grades" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."lead_followups" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."leads" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."lecture_attendance" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."lectures" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."marketing_campaigns" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."notification_receipts" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."procedures" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."programs" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."quiz_answers" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."quiz_bank_questions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."quiz_daily_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."quiz_settings" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."quiz_weekly_scores" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."reservations" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."schedule_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."session_log" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_achievements" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_device_auth_attempts" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_device_bindings" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_disciplinary_actions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_evaluations" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_files" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_passkey_challenges" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_passkey_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_passkeys" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_portal_access_logs" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."student_requests" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."students" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."study_summaries" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."study_summary_activity" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."study_summary_entitlements" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."study_summary_orders" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."study_summary_package_items" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."study_summary_packages" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."study_summary_questions" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."subjects" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."system_settings" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."tasks" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."user_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_employee_activity_audit" AFTER INSERT OR DELETE OR UPDATE ON "public"."weekly_quiz_access_audit" FOR EACH ROW EXECUTE FUNCTION "public"."employee_activity_audit_trigger"();



CREATE OR REPLACE TRIGGER "trg_study_summary_questions_auto_ready" BEFORE INSERT ON "public"."study_summary_questions" FOR EACH ROW EXECUTE FUNCTION "public"."study_summary_questions_default_selected"();



CREATE OR REPLACE TRIGGER "trg_sync_student_status_when_procedure_is_dismissal" AFTER INSERT ON "public"."procedures" FOR EACH ROW EXECUTE FUNCTION "public"."sync_student_status_when_procedure_is_dismissal"();



CREATE OR REPLACE TRIGGER "trg_validate_study_summary_order" BEFORE INSERT ON "public"."study_summary_orders" FOR EACH ROW EXECUTE FUNCTION "public"."validate_study_summary_order"();



ALTER TABLE ONLY "public"."activity_log"
    ADD CONSTRAINT "activity_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alumni_placements"
    ADD CONSTRAINT "alumni_placements_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."attendance_session_exclusions"
    ADD CONSTRAINT "attendance_session_exclusions_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."schedule_sessions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."attendance_session_exclusions"
    ADD CONSTRAINT "attendance_session_exclusions_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."schedule_sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."competition_entries"
    ADD CONSTRAINT "competition_entries_competition_id_fkey" FOREIGN KEY ("competition_id") REFERENCES "public"."competitions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."competition_entries"
    ADD CONSTRAINT "competition_entries_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."exam_attempts"
    ADD CONSTRAINT "exam_attempts_exam_id_fkey" FOREIGN KEY ("exam_id") REFERENCES "public"."exams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."exam_questions"
    ADD CONSTRAINT "exam_questions_exam_id_fkey" FOREIGN KEY ("exam_id") REFERENCES "public"."exams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."exams"
    ADD CONSTRAINT "exams_subject_id_fkey" FOREIGN KEY ("subject_id") REFERENCES "public"."subjects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user_profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "fk_leads_campaign" FOREIGN KEY ("campaign_id") REFERENCES "public"."marketing_campaigns"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."gallery_photos"
    ADD CONSTRAINT "gallery_photos_album_id_fkey" FOREIGN KEY ("album_id") REFERENCES "public"."gallery_albums"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."golden_league_question_starts"
    ADD CONSTRAINT "golden_league_question_starts_question_id_fkey" FOREIGN KEY ("question_id") REFERENCES "public"."quiz_bank_questions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."golden_league_question_starts"
    ADD CONSTRAINT "golden_league_question_starts_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grades"
    ADD CONSTRAINT "grades_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grades"
    ADD CONSTRAINT "grades_subject_id_fkey" FOREIGN KEY ("subject_id") REFERENCES "public"."subjects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."lead_followups"
    ADD CONSTRAINT "lead_followups_lead_id_fkey" FOREIGN KEY ("lead_id") REFERENCES "public"."leads"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user_profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."programs"("id");



ALTER TABLE ONLY "public"."lecture_attendance"
    ADD CONSTRAINT "lecture_attendance_lecture_id_fkey" FOREIGN KEY ("lecture_id") REFERENCES "public"."lectures"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_receipts"
    ADD CONSTRAINT "notification_receipts_notification_id_fkey" FOREIGN KEY ("notification_id") REFERENCES "public"."notifications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notification_receipts"
    ADD CONSTRAINT "notification_receipts_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."procedures"
    ADD CONSTRAINT "procedures_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."procedures"
    ADD CONSTRAINT "procedures_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."session_log"
    ADD CONSTRAINT "session_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_ai_access"
    ADD CONSTRAINT "student_ai_access_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_ai_orders"
    ADD CONSTRAINT "student_ai_orders_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_ai_sessions"
    ADD CONSTRAINT "student_ai_sessions_access_id_fkey" FOREIGN KEY ("access_id") REFERENCES "public"."student_ai_access"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."student_ai_sessions"
    ADD CONSTRAINT "student_ai_sessions_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_ai_usage_daily"
    ADD CONSTRAINT "student_ai_usage_daily_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_device_bindings"
    ADD CONSTRAINT "student_device_bindings_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_disciplinary_actions"
    ADD CONSTRAINT "student_disciplinary_actions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."student_disciplinary_actions"
    ADD CONSTRAINT "student_disciplinary_actions_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."student_evaluations"
    ADD CONSTRAINT "student_evaluations_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."schedule_sessions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."student_evaluations"
    ADD CONSTRAINT "student_evaluations_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_passkey_challenges"
    ADD CONSTRAINT "student_passkey_challenges_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_passkey_sessions"
    ADD CONSTRAINT "student_passkey_sessions_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_passkeys"
    ADD CONSTRAINT "student_passkeys_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_dismissed_by_fkey" FOREIGN KEY ("dismissed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."students"
    ADD CONSTRAINT "students_referred_by_fkey" FOREIGN KEY ("referred_by") REFERENCES "public"."students"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summaries"
    ADD CONSTRAINT "study_summaries_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summaries"
    ADD CONSTRAINT "study_summaries_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summary_activity"
    ADD CONSTRAINT "study_summary_activity_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."study_summary_orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summary_activity"
    ADD CONSTRAINT "study_summary_activity_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summary_activity"
    ADD CONSTRAINT "study_summary_activity_summary_id_fkey" FOREIGN KEY ("summary_id") REFERENCES "public"."study_summaries"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summary_entitlements"
    ADD CONSTRAINT "study_summary_entitlements_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."study_summary_orders"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summary_entitlements"
    ADD CONSTRAINT "study_summary_entitlements_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."study_summary_entitlements"
    ADD CONSTRAINT "study_summary_entitlements_summary_id_fkey" FOREIGN KEY ("summary_id") REFERENCES "public"."study_summaries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."study_summary_orders"
    ADD CONSTRAINT "study_summary_orders_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."study_summary_orders"
    ADD CONSTRAINT "study_summary_orders_student_id_fkey" FOREIGN KEY ("student_id") REFERENCES "public"."students"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."study_summary_orders"
    ADD CONSTRAINT "study_summary_orders_summary_id_fkey" FOREIGN KEY ("summary_id") REFERENCES "public"."study_summaries"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."study_summary_package_items"
    ADD CONSTRAINT "study_summary_package_items_package_id_fkey" FOREIGN KEY ("package_id") REFERENCES "public"."study_summary_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."study_summary_package_items"
    ADD CONSTRAINT "study_summary_package_items_summary_id_fkey" FOREIGN KEY ("summary_id") REFERENCES "public"."study_summaries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."study_summary_questions"
    ADD CONSTRAINT "study_summary_questions_summary_id_fkey" FOREIGN KEY ("summary_id") REFERENCES "public"."study_summaries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_profiles"
    ADD CONSTRAINT "user_profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE "public"."activity_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "activity_log_insert" ON "public"."activity_log" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_active_user"());



CREATE POLICY "activity_log_no_delete" ON "public"."activity_log" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "activity_log_no_update" ON "public"."activity_log" FOR UPDATE TO "authenticated" USING (false);



CREATE POLICY "activity_log_read" ON "public"."activity_log" FOR SELECT TO "authenticated" USING (("public"."is_admin"() OR ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));



ALTER TABLE "public"."ai_conversations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."alumni_placements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "alumni_placements_scoped_access" ON "public"."alumni_placements" TO "authenticated" USING (("public"."is_admin"() OR "public"."can_access_student"("student_id"))) WITH CHECK (("public"."is_admin"() OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."andalus_ai_tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."attendance" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "attendance_admin_all" ON "public"."attendance" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "attendance_employee" ON "public"."attendance" TO "authenticated" USING ("public"."can_access_student"("student_id")) WITH CHECK ("public"."can_access_student"("student_id"));



ALTER TABLE "public"."attendance_session_exclusions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "attendance_session_exclusions_scoped_access" ON "public"."attendance_session_exclusions" TO "authenticated" USING (("public"."is_admin"() OR "public"."can_access_student"("student_id"))) WITH CHECK (("public"."is_admin"() OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."cash_register_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cash_register_logs_admin_only" ON "public"."cash_register_logs" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "cert_templates_all_authenticated" ON "public"."certificate_templates" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."certificate_records" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "certificate_records_admin_manage" ON "public"."certificate_records" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."certificate_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."competition_entries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "competition_entries_active_users_manage" ON "public"."competition_entries" TO "authenticated" USING ("public"."is_active_user"()) WITH CHECK ("public"."is_active_user"());



ALTER TABLE "public"."competition_face_enrollments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."competition_face_verified_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."competition_security_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."competitions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "competitions_active_users_manage" ON "public"."competitions" TO "authenticated" USING ("public"."is_active_user"()) WITH CHECK ("public"."is_active_user"());



ALTER TABLE "public"."contact_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "contact_log_scoped_access" ON "public"."contact_log" TO "authenticated" USING (("public"."is_admin"() OR "public"."can_access_student"("student_id"))) WITH CHECK (("public"."is_admin"() OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."daily_revenue" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "daily_revenue_staff_all_branches" ON "public"."daily_revenue" TO "authenticated" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."user_profiles" "up"
  WHERE (("up"."id" = ( SELECT "auth"."uid"() AS "uid")) AND (COALESCE("up"."is_active", true) = true)))))) WITH CHECK (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."user_profiles" "up"
  WHERE (("up"."id" = ( SELECT "auth"."uid"() AS "uid")) AND (COALESCE("up"."is_active", true) = true))))));



ALTER TABLE "public"."employee_activity_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employee_activity_log_admin_read" ON "public"."employee_activity_log" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "employees_delete_branch" ON "public"."students" FOR DELETE TO "authenticated" USING (("public"."is_active_user"() AND "public"."student_in_user_branch"("branch")));



CREATE POLICY "employees_modify_branch" ON "public"."students" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_active_user"() AND "public"."student_in_user_branch"("branch")));



CREATE POLICY "employees_read_branch" ON "public"."students" FOR SELECT TO "authenticated" USING (("public"."is_active_user"() AND "public"."student_in_user_branch"("branch")));



CREATE POLICY "employees_update_branch" ON "public"."students" FOR UPDATE TO "authenticated" USING (("public"."is_active_user"() AND "public"."student_in_user_branch"("branch"))) WITH CHECK (("public"."is_active_user"() AND "public"."student_in_user_branch"("branch")));



ALTER TABLE "public"."exam_attempts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "exam_attempts_admin_manage" ON "public"."exam_attempts" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."exam_questions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "exam_questions_active_users_manage" ON "public"."exam_questions" TO "authenticated" USING ("public"."is_active_user"()) WITH CHECK ("public"."is_active_user"());



ALTER TABLE "public"."exams" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "exams_active_users_manage" ON "public"."exams" TO "authenticated" USING ("public"."is_active_user"()) WITH CHECK ("public"."is_active_user"());



ALTER TABLE "public"."expenses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "expenses admin modify" ON "public"."expenses" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("user_profiles"."role" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_profiles"
  WHERE (("user_profiles"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("user_profiles"."role" = 'admin'::"text")))));



CREATE POLICY "expenses insert own" ON "public"."expenses" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "created_by"));



CREATE POLICY "expenses read all" ON "public"."expenses" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."gallery_albums" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gallery_albums_branch_access" ON "public"."gallery_albums" TO "authenticated" USING (("public"."is_admin"() OR ("public"."is_active_user"() AND (("branch" IS NULL) OR "public"."student_in_user_branch"("branch"))))) WITH CHECK (("public"."is_admin"() OR ("public"."is_active_user"() AND (("branch" IS NULL) OR "public"."student_in_user_branch"("branch")))));



ALTER TABLE "public"."gallery_photos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gallery_photos_branch_access" ON "public"."gallery_photos" TO "authenticated" USING (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."gallery_albums" "ga"
  WHERE (("ga"."id" = "gallery_photos"."album_id") AND (("ga"."branch" IS NULL) OR "public"."student_in_user_branch"("ga"."branch")) AND "public"."is_active_user"()))))) WITH CHECK (("public"."is_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."gallery_albums" "ga"
  WHERE (("ga"."id" = "gallery_photos"."album_id") AND (("ga"."branch" IS NULL) OR "public"."student_in_user_branch"("ga"."branch")) AND "public"."is_active_user"())))));



ALTER TABLE "public"."golden_league_question_starts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "golden_league_question_starts_admin_only" ON "public"."golden_league_question_starts" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."golden_league_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "golden_league_settings_admin_only" ON "public"."golden_league_settings" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."grades" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "grades_admin_all" ON "public"."grades" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "grades_employee" ON "public"."grades" TO "authenticated" USING ("public"."can_access_student"("student_id")) WITH CHECK ("public"."can_access_student"("student_id"));



ALTER TABLE "public"."lead_followups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lead_followups_branch_access" ON "public"."lead_followups" TO "authenticated" USING (("public"."is_admin"() OR ("public"."is_active_user"() AND (EXISTS ( SELECT 1
   FROM "public"."leads" "l"
  WHERE (("l"."id" = "lead_followups"."lead_id") AND (("l"."branch" IS NULL) OR "public"."student_in_user_branch"("l"."branch")))))))) WITH CHECK (("public"."is_admin"() OR ("public"."is_active_user"() AND (EXISTS ( SELECT 1
   FROM "public"."leads" "l"
  WHERE (("l"."id" = "lead_followups"."lead_id") AND (("l"."branch" IS NULL) OR "public"."student_in_user_branch"("l"."branch"))))))));



ALTER TABLE "public"."leads" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "leads_admin_all" ON "public"."leads" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "leads_employee_branch" ON "public"."leads" TO "authenticated" USING (("public"."is_active_user"() AND (("branch" IS NULL) OR "public"."student_in_user_branch"("branch")))) WITH CHECK (("public"."is_active_user"() AND (("branch" IS NULL) OR "public"."student_in_user_branch"("branch"))));



ALTER TABLE "public"."lecture_attendance" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lecture_attendance_scoped_access" ON "public"."lecture_attendance" TO "authenticated" USING (("public"."is_admin"() OR "public"."can_access_student"("student_id"))) WITH CHECK (("public"."is_admin"() OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."lectures" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lectures_active_users_access" ON "public"."lectures" TO "authenticated" USING ("public"."is_active_user"()) WITH CHECK ("public"."is_active_user"());



ALTER TABLE "public"."marketing_campaigns" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "marketing_campaigns_branch_access" ON "public"."marketing_campaigns" TO "authenticated" USING (("public"."is_admin"() OR ("public"."is_active_user"() AND (("branch" IS NULL) OR "public"."student_in_user_branch"("branch"))))) WITH CHECK (("public"."is_admin"() OR ("public"."is_active_user"() AND (("branch" IS NULL) OR "public"."student_in_user_branch"("branch")))));



ALTER TABLE "public"."notification_receipts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_admin_delete" ON "public"."notifications" FOR DELETE TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "notifications_admin_insert" ON "public"."notifications" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "notifications_admin_select" ON "public"."notifications" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



CREATE POLICY "notifications_admin_update" ON "public"."notifications" FOR UPDATE TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "payments_admin_all" ON "public"."payments" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "payments_employee" ON "public"."payments" TO "authenticated" USING ("public"."can_access_student"("student_id")) WITH CHECK ("public"."can_access_student"("student_id"));



ALTER TABLE "public"."procedures" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "procedures_admin_all" ON "public"."procedures" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "procedures_employee" ON "public"."procedures" TO "authenticated" USING ("public"."can_access_student"("student_id")) WITH CHECK ("public"."can_access_student"("student_id"));



ALTER TABLE "public"."programs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "programs_admin_all" ON "public"."programs" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "programs_read_all" ON "public"."programs" FOR SELECT TO "authenticated" USING ("public"."is_active_user"());



ALTER TABLE "public"."quiz_answers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."quiz_bank_questions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."quiz_daily_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quiz_daily_sessions_public_read" ON "public"."quiz_daily_sessions" FOR SELECT TO "authenticated", "anon" USING (("quiz_date" <= (("now"() AT TIME ZONE 'Africa/Cairo'::"text"))::"date"));



ALTER TABLE "public"."quiz_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quiz_settings_public_read" ON "public"."quiz_settings" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."quiz_weekly_scores" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quiz_weekly_scores_admin_manage" ON "public"."quiz_weekly_scores" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."reservations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reservations_admin_only" ON "public"."reservations" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."schedule_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "schedule_sessions_all_authenticated" ON "public"."schedule_sessions" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."session_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "session_log_insert" ON "public"."session_log" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_active_user"());



CREATE POLICY "session_log_no_delete" ON "public"."session_log" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "session_log_read" ON "public"."session_log" FOR SELECT TO "authenticated" USING (("public"."is_admin"() OR ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));



CREATE POLICY "session_log_update_self" ON "public"."session_log" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."student_achievements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_achievements_admin_delete" ON "public"."student_achievements" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_profiles" "up"
  WHERE (("up"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("up"."role" = 'admin'::"text") AND (COALESCE("up"."is_active", true) = true)))));



CREATE POLICY "student_achievements_admin_insert" ON "public"."student_achievements" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_profiles" "up"
  WHERE (("up"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("up"."role" = 'admin'::"text") AND (COALESCE("up"."is_active", true) = true)))));



CREATE POLICY "student_achievements_admin_select" ON "public"."student_achievements" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_profiles" "up"
  WHERE (("up"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("up"."role" = 'admin'::"text") AND (COALESCE("up"."is_active", true) = true)))));



CREATE POLICY "student_achievements_admin_update" ON "public"."student_achievements" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_profiles" "up"
  WHERE (("up"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("up"."role" = 'admin'::"text") AND (COALESCE("up"."is_active", true) = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_profiles" "up"
  WHERE (("up"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("up"."role" = 'admin'::"text") AND (COALESCE("up"."is_active", true) = true)))));



ALTER TABLE "public"."student_ai_access" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_ai_access_admin_read" ON "public"."student_ai_access" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_admin"() AS "is_admin"));



ALTER TABLE "public"."student_ai_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_ai_orders_admin_read" ON "public"."student_ai_orders" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_admin"() AS "is_admin"));



ALTER TABLE "public"."student_ai_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_ai_sessions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_ai_sessions_admin_read" ON "public"."student_ai_sessions" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_admin"() AS "is_admin"));



ALTER TABLE "public"."student_ai_usage_daily" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_ai_usage_daily_admin_read" ON "public"."student_ai_usage_daily" FOR SELECT TO "authenticated" USING (( SELECT "public"."is_admin"() AS "is_admin"));



ALTER TABLE "public"."student_device_auth_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_device_bindings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_disciplinary_actions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_disciplinary_actions_scoped_access" ON "public"."student_disciplinary_actions" TO "authenticated" USING (("public"."is_admin"() OR "public"."can_access_student"("student_id"))) WITH CHECK (("public"."is_admin"() OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."student_evaluations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_evaluations_scoped_access" ON "public"."student_evaluations" TO "authenticated" USING (("public"."is_admin"() OR "public"."can_access_student"("student_id"))) WITH CHECK (("public"."is_admin"() OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."student_files" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_files_scoped_access" ON "public"."student_files" TO "authenticated" USING (("public"."is_admin"() OR "public"."can_access_student"("student_id"))) WITH CHECK (("public"."is_admin"() OR "public"."can_access_student"("student_id")));



ALTER TABLE "public"."student_passkey_challenges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_passkey_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_passkeys" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_portal_access_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_portal_access_logs_no_delete" ON "public"."student_portal_access_logs" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "student_portal_access_logs_no_insert" ON "public"."student_portal_access_logs" FOR INSERT TO "authenticated" WITH CHECK (false);



CREATE POLICY "student_portal_access_logs_no_update" ON "public"."student_portal_access_logs" FOR UPDATE TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "student_portal_access_logs_read" ON "public"."student_portal_access_logs" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



ALTER TABLE "public"."student_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "student_requests_admin_all" ON "public"."student_requests" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."students" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "students_admin_all" ON "public"."students" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."study_summaries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "study_summaries_admin_all" ON "public"."study_summaries" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "study_summaries_public_catalog" ON "public"."study_summaries" FOR SELECT TO "authenticated", "anon" USING (("is_published" = true));



ALTER TABLE "public"."study_summary_activity" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "study_summary_activity_admin_insert" ON "public"."study_summary_activity" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_admin"());



CREATE POLICY "study_summary_activity_admin_select" ON "public"."study_summary_activity" FOR SELECT TO "authenticated" USING ("public"."is_admin"());



ALTER TABLE "public"."study_summary_entitlements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "study_summary_entitlements_admin_all" ON "public"."study_summary_entitlements" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."study_summary_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "study_summary_orders_admin_all" ON "public"."study_summary_orders" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "study_summary_orders_student_create" ON "public"."study_summary_orders" FOR INSERT TO "authenticated", "anon" WITH CHECK (("status" = 'pending'::"text"));



ALTER TABLE "public"."study_summary_package_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."study_summary_packages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."study_summary_questions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "study_summary_questions_admin_all" ON "public"."study_summary_questions" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



ALTER TABLE "public"."subjects" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "subjects_admin_all" ON "public"."subjects" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "subjects_read_all" ON "public"."subjects" FOR SELECT TO "authenticated" USING ("public"."is_active_user"());



ALTER TABLE "public"."system_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "system_settings_admin_manage" ON "public"."system_settings" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "system_settings_public_display_read" ON "public"."system_settings" FOR SELECT TO "anon" USING (("key" = ANY (ARRAY['system_name'::"text", 'whatsapp_news_link'::"text"])));



ALTER TABLE "public"."tasks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tasks_all_authenticated" ON "public"."tasks" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."user_profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_profiles_admin_all" ON "public"."user_profiles" TO "authenticated" USING ("public"."is_admin"()) WITH CHECK ("public"."is_admin"());



CREATE POLICY "user_profiles_self_read" ON "public"."user_profiles" FOR SELECT TO "authenticated" USING ((("id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_admin"()));



ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."weekly_quiz_access_audit" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_add_weekly_quiz_question"("p_question" "text", "p_option_a" "text", "p_option_b" "text", "p_option_c" "text", "p_option_d" "text", "p_correct_option" "text", "p_category" "text", "p_points" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_add_weekly_quiz_question"("p_question" "text", "p_option_a" "text", "p_option_b" "text", "p_option_c" "text", "p_option_d" "text", "p_correct_option" "text", "p_category" "text", "p_points" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_add_weekly_quiz_question"("p_question" "text", "p_option_a" "text", "p_option_b" "text", "p_option_c" "text", "p_option_d" "text", "p_correct_option" "text", "p_category" "text", "p_points" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_archive_study_summary_order"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_archive_study_summary_order"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_archive_study_summary_order"("p_order_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_get_weekly_quiz_bank"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_get_weekly_quiz_bank"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_get_weekly_quiz_bank"() TO "service_role";



GRANT ALL ON TABLE "public"."weekly_quiz_access_audit" TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_identity_verification_report"("p_limit" integer, "p_outcome" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_identity_verification_report"("p_limit" integer, "p_outcome" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_identity_verification_report"("p_limit" integer, "p_outcome" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_identity_verification_summary"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_identity_verification_summary"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_identity_verification_summary"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_reset_all_student_face_enrollments"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reset_all_student_face_enrollments"() TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_reset_all_student_face_enrollments"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_reset_identity_registration"("p_student_ref" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reset_identity_registration"("p_student_ref" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_reset_identity_registration"("p_student_ref" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_reset_student_device_binding"("p_student_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reset_student_device_binding"("p_student_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_reset_student_device_binding"("p_student_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_reset_student_face_enrollment"("p_student_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reset_student_face_enrollment"("p_student_id" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."admin_reset_student_face_enrollment"("p_student_id" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_review_study_summary_order"("p_order_id" "uuid", "p_status" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_review_study_summary_order"("p_order_id" "uuid", "p_status" "text", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_review_study_summary_order"("p_order_id" "uuid", "p_status" "text", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_update_weekly_quiz_settings"("p_daily_time" "text", "p_questions_per_day" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_update_weekly_quiz_settings"("p_daily_time" "text", "p_questions_per_day" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_update_weekly_quiz_settings"("p_daily_time" "text", "p_questions_per_day" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "jsonb", "p_measure_column" "text", "p_operation" "text", "p_filters" "jsonb", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "jsonb", "p_measure_column" "text", "p_operation" "text", "p_filters" "jsonb", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "text"[], "p_count_column" "text", "p_sum_column" "text", "p_avg_column" "text", "p_min_column" "text", "p_max_column" "text", "p_filters" "jsonb", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ai_aggregate"("p_table" "text", "p_group_by" "text"[], "p_count_column" "text", "p_sum_column" "text", "p_avg_column" "text", "p_min_column" "text", "p_max_column" "text", "p_filters" "jsonb", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[], "p_filters" "jsonb", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[], "p_filters" "jsonb", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[], "p_filters" "jsonb", "p_order_by" "text", "p_order_desc" boolean, "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "text"[], "p_filters" "jsonb", "p_order_by" "text", "p_order_desc" boolean, "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "jsonb", "p_filters" "jsonb", "p_order_by" "text", "p_order_desc" boolean, "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ai_read"("p_table" "text", "p_columns" "jsonb", "p_filters" "jsonb", "p_order_by" "text", "p_order_desc" boolean, "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."ai_schema"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ai_schema"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."audit_log_event"("p_action_type" "text", "p_module" "text", "p_title" "text", "p_details" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."audit_log_event"("p_action_type" "text", "p_module" "text", "p_title" "text", "p_details" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_log_event"("p_action_type" "text", "p_module" "text", "p_title" "text", "p_details" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."audit_log_get_user"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."audit_log_get_user"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_log_get_user"("p_user_id" "uuid", "p_page" integer, "p_page_size" integer) TO "service_role";



GRANT ALL ON TABLE "public"."user_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."user_profiles" TO "service_role";



REVOKE ALL ON FUNCTION "public"."audit_log_get_users"("p_search" "text", "p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."audit_log_get_users"("p_search" "text", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_log_get_users"("p_search" "text", "p_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_log_sanitize"("p" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."audit_log_sanitize"("p" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_log_sanitize"("p" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."auto_activate_daily_quiz"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."auto_activate_daily_quiz"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_hide_expelled_student"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_hide_expelled_student"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_hide_expelled_student"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."award_attendance_milestone"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."award_attendance_milestone"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_access_student"("p_student_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_access_student"("p_student_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_upload_study_summary_payment_proof"("p_session_token" "text", "p_order_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_upload_study_summary_payment_proof"("p_session_token" "text", "p_order_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."can_upload_study_summary_payment_proof"("p_session_token" "text", "p_order_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_upload_study_summary_payment_proof"("p_session_token" "text", "p_order_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."can_upload_weekly_quiz_audit"("p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_upload_weekly_quiz_audit"("p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."can_upload_weekly_quiz_audit"("p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_upload_weekly_quiz_audit"("p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_pending_summary_orders_after_access"() TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_pending_summary_orders_after_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_pending_summary_orders_after_access"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."competition_identity_admin_report"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."competition_identity_admin_report"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."competition_identity_admin_report"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."competition_security_admin_logs"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."competition_security_admin_logs"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."competition_security_admin_logs"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."dismiss_student"("p_student_id" "text", "p_reason" "text", "p_decision_number" "text", "p_action_date" "date", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dismiss_student"("p_student_id" "text", "p_reason" "text", "p_decision_number" "text", "p_action_date" "date", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dismiss_student"("p_student_id" "text", "p_reason" "text", "p_decision_number" "text", "p_action_date" "date", "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."employee_activity_audit_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."employee_activity_audit_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."employee_activity_audit_trigger"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."ensure_weekly_quiz_session"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_weekly_quiz_session"() TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_weekly_quiz_session"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_weekly_quiz_session"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."final_dismiss_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."final_dismiss_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."final_dismiss_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_portal_notifications"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_portal_notifications"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_portal_notifications"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_portal_notifications"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_public_competition"("p_competition_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_public_competition"("p_competition_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_competition"("p_competition_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_competition"("p_competition_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_public_portal_announcements"("p_portal_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_portal_announcements"("p_portal_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_portal_announcements"("p_portal_type" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_public_student_card"("p_student_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_public_student_card"("p_student_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_public_student_card"("p_student_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_public_student_card"("p_student_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_student_branch"("p_student_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_student_branch"("p_student_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_branch"("p_student_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_student_requests"("p_student_id" "text", "p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_student_requests"("p_student_id" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_requests"("p_student_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_requests"("p_student_id" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_student_summary_catalog"("p_student_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_student_summary_catalog"("p_student_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_student_summary_content"("p_student_id" "text", "p_summary_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_student_summary_content"("p_student_id" "text", "p_summary_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_user_branch"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_user_branch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_branch"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_user_role"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."golden_league_cycle_start"("p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."golden_league_cycle_start"("p_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."golden_league_cycle_start"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."golden_league_cycle_start"("p_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."golden_league_admin_report"("p_cycle_start" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."golden_league_admin_report"("p_cycle_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."golden_league_admin_report"("p_cycle_start" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."golden_league_get_settings_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."golden_league_get_settings_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."golden_league_get_settings_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."golden_league_get_student_dashboard"("p_student_id" "text", "p_face_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."golden_league_get_student_dashboard"("p_student_id" "text", "p_face_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."golden_league_get_student_dashboard"("p_student_id" "text", "p_face_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."golden_league_update_settings"("p_daily_start" "text", "p_daily_end" "text", "p_questions_per_day" integer, "p_points_per_question" integer, "p_weekly_thresholds" integer[], "p_weekly_seconds" integer[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."golden_league_update_settings"("p_daily_start" "text", "p_daily_end" "text", "p_questions_per_day" integer, "p_points_per_question" integer, "p_weekly_thresholds" integer[], "p_weekly_seconds" integer[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."golden_league_update_settings"("p_daily_start" "text", "p_daily_end" "text", "p_questions_per_day" integer, "p_points_per_question" integer, "p_weekly_thresholds" integer[], "p_weekly_seconds" integer[]) TO "service_role";



REVOKE ALL ON FUNCTION "public"."golden_league_week_number"("p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."golden_league_week_number"("p_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."golden_league_week_number"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."golden_league_week_number"("p_date" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_active_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_active_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_active_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."is_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_portal_notification_read"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text", "p_notification_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_portal_notification_read"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text", "p_notification_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_portal_notification_read"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text", "p_notification_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_portal_notification_read"("p_student_id" "text", "p_phone" "text", "p_portal_type" "text", "p_notification_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."normalize_eg_phone"("p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."normalize_eg_phone"("p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_eg_phone"("p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_eg_phone"("p_phone" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_student_login_digits"("p_value" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_student_login_digits"("p_value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_student_login_digits"("p_value" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."parent_portal_get_data"("p_student_id" "text", "p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."parent_portal_get_data"("p_student_id" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."parent_portal_get_data"("p_student_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."parent_portal_get_data"("p_student_id" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."public_student_lookup"("p_student_id" "text", "p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."public_student_lookup"("p_student_id" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."public_student_lookup"("p_student_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."public_student_lookup"("p_student_id" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."require_competition_face_verification"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."require_competition_face_verification"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."restore_dismissed_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_dismissed_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restore_dismissed_student"("p_student_id" "text", "p_decision_number" "text", "p_action_date" "date", "p_reason" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_ai_admin_dashboard"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_ai_admin_dashboard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_ai_admin_dashboard"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_ai_admin_grant_access"("p_student_id" "text", "p_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_ai_admin_grant_access"("p_student_id" "text", "p_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_ai_admin_grant_access"("p_student_id" "text", "p_days" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_ai_admin_list_orders"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_ai_admin_list_orders"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_ai_admin_list_orders"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_ai_admin_revoke_access"("p_student_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_ai_admin_revoke_access"("p_student_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_ai_admin_revoke_access"("p_student_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_ai_admin_subscription_report"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_ai_admin_subscription_report"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_ai_admin_subscription_report"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_ai_approve_order"("p_order_id" "uuid", "p_reviewer" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_ai_approve_order"("p_order_id" "uuid", "p_reviewer" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_ai_approve_order"("p_order_id" "uuid", "p_reviewer" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_ai_reject_order"("p_order_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_ai_reject_order"("p_order_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_ai_reject_order"("p_order_id" "uuid", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_create_paid_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_create_paid_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_create_paid_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_create_paid_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid", "p_access_hours" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid", "p_access_hours" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_create_study_summary_order"("p_session_token" "uuid", "p_summary_id" "uuid", "p_access_hours" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_device_auth"("p_student_code" "text", "p_national_id" "text", "p_device_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_device_auth"("p_student_code" "text", "p_national_id" "text", "p_device_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_device_auth"("p_student_code" "text", "p_national_id" "text", "p_device_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_device_auth"("p_student_code" "text", "p_national_id" "text", "p_device_token" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid", "p_passkey_session_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid", "p_passkey_session_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid", "p_passkey_session_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_device_issue_context_token"("p_student_id" "text", "p_device_token" "text", "p_context_type" "text", "p_context_id" "uuid", "p_passkey_session_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_exam_list"("p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_exam_list"("p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_exam_list"("p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_exam_list"("p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_exam_resume_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_exam_resume_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_exam_resume_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_exam_resume_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_exam_save_answers"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_exam_save_answers"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."student_exam_save_answers"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_exam_save_answers"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_exam_start_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_exam_start_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_exam_start_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_exam_start_attempt"("p_exam_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_exam_submit_attempt"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb", "p_cheating" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_exam_submit_attempt"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb", "p_cheating" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."student_exam_submit_attempt"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb", "p_cheating" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_exam_submit_attempt"("p_attempt_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answers" "jsonb", "p_cheating" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" double precision, "p_face_threshold" double precision, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" double precision, "p_face_threshold" double precision, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" double precision, "p_face_threshold" double precision, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" numeric, "p_face_threshold" numeric, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" numeric, "p_face_threshold" numeric, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_face_audit_finalize"("p_student_id" "text", "p_outcome" "text", "p_failure_code" "text", "p_failure_reason" "text", "p_face_distance" numeric, "p_face_threshold" numeric, "p_reference_photo_url" "text", "p_verification_method" "text", "p_session_token" "uuid", "p_metadata" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_face_enroll"("p_student_id" "text", "p_phone" "text", "p_descriptor" "jsonb", "p_consent" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_face_enroll"("p_student_id" "text", "p_phone" "text", "p_descriptor" "jsonb", "p_consent" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."student_face_enroll"("p_student_id" "text", "p_phone" "text", "p_descriptor" "jsonb", "p_consent" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_face_enroll"("p_student_id" "text", "p_phone" "text", "p_descriptor" "jsonb", "p_consent" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_face_phone_matches"("p_student_id" "text", "p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_face_phone_matches"("p_student_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_face_phone_matches"("p_student_id" "text", "p_phone" "text") TO "service_role";



GRANT ALL ON TABLE "public"."students" TO "anon";
GRANT ALL ON TABLE "public"."students" TO "authenticated";
GRANT ALL ON TABLE "public"."students" TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_face_resolve"("p_student_ref" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_face_resolve"("p_student_ref" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_face_status"("p_student_id" "text", "p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_face_status"("p_student_id" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_face_status"("p_student_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_face_status"("p_student_id" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_face_verify"("p_student_id" "text", "p_phone" "text", "p_live_descriptor" "jsonb", "p_competition_type" "text", "p_competition_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_face_verify"("p_student_id" "text", "p_phone" "text", "p_live_descriptor" "jsonb", "p_competition_type" "text", "p_competition_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_face_verify"("p_student_id" "text", "p_phone" "text", "p_live_descriptor" "jsonb", "p_competition_type" "text", "p_competition_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_face_verify"("p_student_id" "text", "p_phone" "text", "p_live_descriptor" "jsonb", "p_competition_type" "text", "p_competition_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_get_study_summary_question"("p_session_token" "uuid", "p_summary_id" "uuid", "p_question_number" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_get_study_summary_question"("p_session_token" "uuid", "p_summary_id" "uuid", "p_question_number" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."student_get_study_summary_question"("p_session_token" "uuid", "p_summary_id" "uuid", "p_question_number" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_get_study_summary_question"("p_session_token" "uuid", "p_summary_id" "uuid", "p_question_number" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_hide_completed_request"("p_student_id" "text", "p_phone" "text", "p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_hide_completed_request"("p_student_id" "text", "p_phone" "text", "p_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_hide_completed_request"("p_student_id" "text", "p_phone" "text", "p_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_hide_completed_request"("p_student_id" "text", "p_phone" "text", "p_request_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_hide_study_summary_order"("p_session_token" "uuid", "p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_hide_study_summary_order"("p_session_token" "uuid", "p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_hide_study_summary_order"("p_session_token" "uuid", "p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_hide_study_summary_order"("p_session_token" "uuid", "p_order_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."student_identity_check"("p_student_ref" "text", "p_national_id" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_identity_check"("p_student_ref" "text", "p_national_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_identity_check"("p_student_ref" "text", "p_national_id" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_in_user_branch"("p_branch" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_in_user_branch"("p_branch" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_in_user_branch"("p_branch" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_list_study_summaries"("p_session_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_list_study_summaries"("p_session_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_list_study_summaries"("p_session_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_list_study_summaries"("p_session_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_list_study_summary_orders"("p_session_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_list_study_summary_orders"("p_session_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."student_list_study_summary_orders"("p_session_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_list_study_summary_orders"("p_session_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_portal_get_achievements"("p_student_id" "text", "p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_portal_get_achievements"("p_student_id" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_portal_get_achievements"("p_student_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_portal_get_achievements"("p_student_id" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_portal_get_ranking"("p_student_id" "text", "p_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_portal_get_ranking"("p_student_id" "text", "p_phone" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_portal_get_ranking"("p_student_id" "text", "p_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_portal_get_ranking"("p_student_id" "text", "p_phone" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_record_study_summary_payment_proof"("p_session_token" "uuid", "p_order_id" "uuid", "p_proof_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_record_study_summary_payment_proof"("p_session_token" "uuid", "p_order_id" "uuid", "p_proof_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_record_study_summary_payment_proof"("p_session_token" "uuid", "p_order_id" "uuid", "p_proof_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_record_study_summary_payment_proof"("p_session_token" "uuid", "p_order_id" "uuid", "p_proof_path" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."student_submit_study_summary_payment_reference"("p_session_token" "uuid", "p_order_id" "uuid", "p_payment_reference" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."student_submit_study_summary_payment_reference"("p_session_token" "uuid", "p_order_id" "uuid", "p_payment_reference" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."student_submit_study_summary_payment_reference"("p_session_token" "uuid", "p_order_id" "uuid", "p_payment_reference" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."student_submit_study_summary_payment_reference"("p_session_token" "uuid", "p_order_id" "uuid", "p_payment_reference" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."study_summary_questions_default_selected"() TO "anon";
GRANT ALL ON FUNCTION "public"."study_summary_questions_default_selected"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."study_summary_questions_default_selected"() TO "service_role";



GRANT ALL ON FUNCTION "public"."study_summary_target_matches"("p_target" "text", "p_student_value" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."study_summary_target_matches"("p_target" "text", "p_student_value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."study_summary_target_matches"("p_target" "text", "p_student_value" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_public_competition_entry"("p_competition_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answer_text" "text", "p_photo_url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_public_competition_entry"("p_competition_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answer_text" "text", "p_photo_url" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_public_competition_entry"("p_competition_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answer_text" "text", "p_photo_url" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_public_competition_entry"("p_competition_id" "uuid", "p_student_id" "text", "p_phone" "text", "p_face_token" "uuid", "p_answer_text" "text", "p_photo_url" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_student_request"("p_student_id" "text", "p_phone" "text", "p_requester_type" "text", "p_request_type" "text", "p_title" "text", "p_description" "text", "p_priority" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_student_request"("p_student_id" "text", "p_phone" "text", "p_requester_type" "text", "p_request_type" "text", "p_title" "text", "p_description" "text", "p_priority" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_student_request"("p_student_id" "text", "p_phone" "text", "p_requester_type" "text", "p_request_type" "text", "p_title" "text", "p_description" "text", "p_priority" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_student_request"("p_student_id" "text", "p_phone" "text", "p_requester_type" "text", "p_request_type" "text", "p_title" "text", "p_description" "text", "p_priority" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_daily_revenue_to_student_finance"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_daily_revenue_to_student_finance"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_daily_revenue_to_student_finance"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_student_status_when_procedure_is_dismissal"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_student_status_when_procedure_is_dismissal"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_student_status_when_procedure_is_dismissal"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."trainer_kiosk_get_attendance"("p_code" "text", "p_session_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trainer_kiosk_get_attendance"("p_code" "text", "p_session_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."trainer_kiosk_get_attendance"("p_code" "text", "p_session_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trainer_kiosk_get_attendance"("p_code" "text", "p_session_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."trainer_kiosk_get_sessions"("p_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trainer_kiosk_get_sessions"("p_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."trainer_kiosk_get_sessions"("p_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trainer_kiosk_get_sessions"("p_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."trainer_kiosk_mark_attendance"("p_code" "text", "p_session_id" "text", "p_student_id" "text", "p_status" "text", "p_date" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trainer_kiosk_mark_attendance"("p_code" "text", "p_session_id" "text", "p_student_id" "text", "p_status" "text", "p_date" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."trainer_kiosk_mark_attendance"("p_code" "text", "p_session_id" "text", "p_student_id" "text", "p_status" "text", "p_date" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trainer_kiosk_mark_attendance"("p_code" "text", "p_session_id" "text", "p_student_id" "text", "p_status" "text", "p_date" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_study_summary_order"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_study_summary_order"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_study_summary_order"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."verify_certificate_by_serial"("p_serial" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."verify_certificate_by_serial"("p_serial" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."verify_certificate_by_serial"("p_serial" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_certificate_by_serial"("p_serial" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."weekly_quiz_admin_audit"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."weekly_quiz_admin_audit"("p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."weekly_quiz_admin_audit"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."weekly_quiz_get_answered_questions"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_answered_questions"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_answered_questions"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_answered_questions"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."weekly_quiz_get_public_questions"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_public_questions"() TO "anon";
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_public_questions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_public_questions"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."weekly_quiz_get_public_scores"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_public_scores"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_public_scores"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."weekly_quiz_get_public_scores"("p_student_id" "text", "p_face_token" "uuid", "p_week_start" "date") TO "service_role";



REVOKE ALL ON FUNCTION "public"."weekly_quiz_log_entry"("p_student_id" "text", "p_photo_path" "text", "p_face_token" "uuid", "p_user_agent" "text", "p_browser_name" "text", "p_device_label" "text", "p_photo_consent" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."weekly_quiz_log_entry"("p_student_id" "text", "p_photo_path" "text", "p_face_token" "uuid", "p_user_agent" "text", "p_browser_name" "text", "p_device_label" "text", "p_photo_consent" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."weekly_quiz_log_entry"("p_student_id" "text", "p_photo_path" "text", "p_face_token" "uuid", "p_user_agent" "text", "p_browser_name" "text", "p_device_label" "text", "p_photo_consent" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."weekly_quiz_log_entry"("p_student_id" "text", "p_photo_path" "text", "p_face_token" "uuid", "p_user_agent" "text", "p_browser_name" "text", "p_device_label" "text", "p_photo_consent" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."weekly_quiz_start_question"("p_student_id" "text", "p_quiz_date" "date", "p_question_id" "uuid", "p_face_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."weekly_quiz_start_question"("p_student_id" "text", "p_quiz_date" "date", "p_question_id" "uuid", "p_face_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."weekly_quiz_start_question"("p_student_id" "text", "p_quiz_date" "date", "p_question_id" "uuid", "p_face_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."weekly_quiz_submit_answer"("p_quiz_date" "date", "p_student_id" "text", "p_question_id" "uuid", "p_selected_option" "text", "p_face_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."weekly_quiz_submit_answer"("p_quiz_date" "date", "p_student_id" "text", "p_question_id" "uuid", "p_selected_option" "text", "p_face_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."weekly_quiz_submit_answer"("p_quiz_date" "date", "p_student_id" "text", "p_question_id" "uuid", "p_selected_option" "text", "p_face_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."weekly_quiz_submit_answer"("p_quiz_date" "date", "p_student_id" "text", "p_question_id" "uuid", "p_selected_option" "text", "p_face_token" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."activity_log" TO "authenticated";
GRANT ALL ON TABLE "public"."activity_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."activity_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."activity_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."activity_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ai_conversations" TO "service_role";



GRANT ALL ON TABLE "public"."alumni_placements" TO "anon";
GRANT ALL ON TABLE "public"."alumni_placements" TO "authenticated";
GRANT ALL ON TABLE "public"."alumni_placements" TO "service_role";



GRANT ALL ON TABLE "public"."andalus_ai_tasks" TO "anon";
GRANT ALL ON TABLE "public"."andalus_ai_tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."andalus_ai_tasks" TO "service_role";



GRANT ALL ON TABLE "public"."attendance" TO "anon";
GRANT ALL ON TABLE "public"."attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance" TO "service_role";



GRANT ALL ON TABLE "public"."attendance_session_exclusions" TO "anon";
GRANT ALL ON TABLE "public"."attendance_session_exclusions" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance_session_exclusions" TO "service_role";



GRANT ALL ON TABLE "public"."cash_register_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."cash_register_logs" TO "service_role";



GRANT ALL ON TABLE "public"."certificate_records" TO "anon";
GRANT ALL ON TABLE "public"."certificate_records" TO "authenticated";
GRANT ALL ON TABLE "public"."certificate_records" TO "service_role";



GRANT ALL ON TABLE "public"."certificate_templates" TO "anon";
GRANT ALL ON TABLE "public"."certificate_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."certificate_templates" TO "service_role";



GRANT ALL ON TABLE "public"."competition_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."competition_entries" TO "service_role";



GRANT ALL ON TABLE "public"."competition_face_enrollments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."competition_face_enrollments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."competition_face_enrollments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."competition_face_enrollments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."competition_face_verified_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."competition_security_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."competition_security_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."competition_security_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."competition_security_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."competitions" TO "authenticated";
GRANT ALL ON TABLE "public"."competitions" TO "service_role";



GRANT ALL ON TABLE "public"."contact_log" TO "anon";
GRANT ALL ON TABLE "public"."contact_log" TO "authenticated";
GRANT ALL ON TABLE "public"."contact_log" TO "service_role";



GRANT ALL ON TABLE "public"."daily_revenue" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_revenue" TO "service_role";



GRANT ALL ON SEQUENCE "public"."daily_revenue_serial_no_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."daily_revenue_serial_no_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."daily_revenue_serial_no_seq" TO "service_role";



GRANT ALL ON TABLE "public"."employee_activity_log" TO "service_role";
GRANT SELECT ON TABLE "public"."employee_activity_log" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."employee_activity_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."employee_activity_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."employee_activity_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."employees_full_profile" TO "service_role";



GRANT ALL ON TABLE "public"."exam_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."exam_attempts" TO "service_role";



GRANT ALL ON TABLE "public"."exam_questions" TO "authenticated";
GRANT ALL ON TABLE "public"."exam_questions" TO "service_role";



GRANT ALL ON TABLE "public"."exams" TO "authenticated";
GRANT ALL ON TABLE "public"."exams" TO "service_role";



GRANT ALL ON TABLE "public"."expenses" TO "authenticated";
GRANT ALL ON TABLE "public"."expenses" TO "service_role";



GRANT ALL ON TABLE "public"."expense_totals" TO "service_role";



GRANT ALL ON TABLE "public"."gallery_albums" TO "anon";
GRANT ALL ON TABLE "public"."gallery_albums" TO "authenticated";
GRANT ALL ON TABLE "public"."gallery_albums" TO "service_role";



GRANT ALL ON TABLE "public"."gallery_photos" TO "anon";
GRANT ALL ON TABLE "public"."gallery_photos" TO "authenticated";
GRANT ALL ON TABLE "public"."gallery_photos" TO "service_role";



GRANT ALL ON TABLE "public"."golden_league_question_starts" TO "anon";
GRANT ALL ON TABLE "public"."golden_league_question_starts" TO "authenticated";
GRANT ALL ON TABLE "public"."golden_league_question_starts" TO "service_role";



GRANT ALL ON TABLE "public"."golden_league_settings" TO "anon";
GRANT ALL ON TABLE "public"."golden_league_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."golden_league_settings" TO "service_role";



GRANT ALL ON TABLE "public"."grades" TO "anon";
GRANT ALL ON TABLE "public"."grades" TO "authenticated";
GRANT ALL ON TABLE "public"."grades" TO "service_role";



GRANT ALL ON TABLE "public"."lead_followups" TO "authenticated";
GRANT ALL ON TABLE "public"."lead_followups" TO "service_role";



GRANT ALL ON TABLE "public"."leads" TO "authenticated";
GRANT ALL ON TABLE "public"."leads" TO "service_role";



GRANT ALL ON TABLE "public"."lecture_attendance" TO "anon";
GRANT ALL ON TABLE "public"."lecture_attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."lecture_attendance" TO "service_role";



GRANT ALL ON TABLE "public"."lectures" TO "anon";
GRANT ALL ON TABLE "public"."lectures" TO "authenticated";
GRANT ALL ON TABLE "public"."lectures" TO "service_role";



GRANT ALL ON TABLE "public"."marketing_campaigns" TO "authenticated";
GRANT ALL ON TABLE "public"."marketing_campaigns" TO "service_role";



GRANT ALL ON TABLE "public"."notification_receipts" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON TABLE "public"."procedures" TO "authenticated";
GRANT ALL ON TABLE "public"."procedures" TO "service_role";



GRANT ALL ON TABLE "public"."programs" TO "anon";
GRANT ALL ON TABLE "public"."programs" TO "authenticated";
GRANT ALL ON TABLE "public"."programs" TO "service_role";



GRANT ALL ON TABLE "public"."quiz_answers" TO "service_role";



GRANT ALL ON TABLE "public"."quiz_bank_questions" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("id") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("question") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("question") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("option_a") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("option_a") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("option_b") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("option_b") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("option_c") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("option_c") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("option_d") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("option_d") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("category") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("category") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("points") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("points") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("active") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("active") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."quiz_bank_questions" TO "anon";
GRANT SELECT("created_at") ON TABLE "public"."quiz_bank_questions" TO "authenticated";



GRANT ALL ON TABLE "public"."quiz_daily_sessions" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."quiz_daily_sessions" TO "anon";
GRANT SELECT("id") ON TABLE "public"."quiz_daily_sessions" TO "authenticated";



GRANT SELECT("quiz_date") ON TABLE "public"."quiz_daily_sessions" TO "anon";
GRANT SELECT("quiz_date") ON TABLE "public"."quiz_daily_sessions" TO "authenticated";



GRANT SELECT("question_ids") ON TABLE "public"."quiz_daily_sessions" TO "anon";
GRANT SELECT("question_ids") ON TABLE "public"."quiz_daily_sessions" TO "authenticated";



GRANT SELECT("activated_at") ON TABLE "public"."quiz_daily_sessions" TO "anon";
GRANT SELECT("activated_at") ON TABLE "public"."quiz_daily_sessions" TO "authenticated";



GRANT ALL ON TABLE "public"."quiz_settings" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."quiz_settings" TO "anon";
GRANT SELECT("id") ON TABLE "public"."quiz_settings" TO "authenticated";



GRANT SELECT("daily_time") ON TABLE "public"."quiz_settings" TO "anon";
GRANT SELECT("daily_time") ON TABLE "public"."quiz_settings" TO "authenticated";



GRANT SELECT("questions_per_day") ON TABLE "public"."quiz_settings" TO "anon";
GRANT SELECT("questions_per_day") ON TABLE "public"."quiz_settings" TO "authenticated";



GRANT SELECT("updated_at") ON TABLE "public"."quiz_settings" TO "anon";
GRANT SELECT("updated_at") ON TABLE "public"."quiz_settings" TO "authenticated";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."quiz_weekly_scores" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."quiz_weekly_scores" TO "authenticated";
GRANT ALL ON TABLE "public"."quiz_weekly_scores" TO "service_role";



GRANT ALL ON TABLE "public"."reservations" TO "authenticated";
GRANT ALL ON TABLE "public"."reservations" TO "service_role";



GRANT ALL ON TABLE "public"."schedule_sessions" TO "anon";
GRANT ALL ON TABLE "public"."schedule_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."schedule_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."session_log" TO "authenticated";
GRANT ALL ON TABLE "public"."session_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."session_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."session_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."session_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."student_achievements" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."student_achievements" TO "authenticated";



GRANT ALL ON TABLE "public"."student_ai_access" TO "service_role";
GRANT SELECT ON TABLE "public"."student_ai_access" TO "authenticated";



GRANT ALL ON TABLE "public"."student_ai_orders" TO "service_role";
GRANT SELECT ON TABLE "public"."student_ai_orders" TO "authenticated";



GRANT ALL ON TABLE "public"."student_ai_plans" TO "service_role";
GRANT SELECT ON TABLE "public"."student_ai_plans" TO "authenticated";



GRANT ALL ON TABLE "public"."student_ai_sessions" TO "service_role";
GRANT SELECT ON TABLE "public"."student_ai_sessions" TO "authenticated";



GRANT ALL ON TABLE "public"."student_ai_usage_daily" TO "service_role";
GRANT SELECT ON TABLE "public"."student_ai_usage_daily" TO "authenticated";



GRANT ALL ON TABLE "public"."student_device_auth_attempts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."student_device_auth_attempts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."student_device_auth_attempts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."student_device_auth_attempts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."student_device_bindings" TO "service_role";



GRANT ALL ON TABLE "public"."student_disciplinary_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."student_disciplinary_actions" TO "service_role";



GRANT ALL ON TABLE "public"."student_evaluations" TO "authenticated";
GRANT ALL ON TABLE "public"."student_evaluations" TO "service_role";



GRANT ALL ON TABLE "public"."student_files" TO "authenticated";
GRANT ALL ON TABLE "public"."student_files" TO "service_role";



GRANT ALL ON SEQUENCE "public"."student_files_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."student_files_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."student_files_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."student_passkey_challenges" TO "service_role";



GRANT ALL ON TABLE "public"."student_passkey_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."student_passkeys" TO "service_role";



GRANT ALL ON TABLE "public"."student_portal_access_logs" TO "anon";
GRANT ALL ON TABLE "public"."student_portal_access_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."student_portal_access_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."student_portal_access_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."student_portal_access_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."student_portal_access_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."student_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."student_requests" TO "service_role";



GRANT ALL ON TABLE "public"."study_summaries" TO "authenticated";
GRANT ALL ON TABLE "public"."study_summaries" TO "service_role";
GRANT SELECT ON TABLE "public"."study_summaries" TO "anon";



GRANT ALL ON TABLE "public"."study_summary_activity" TO "authenticated";
GRANT ALL ON TABLE "public"."study_summary_activity" TO "service_role";



GRANT ALL ON SEQUENCE "public"."study_summary_activity_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."study_summary_activity_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."study_summary_activity_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."study_summary_entitlements" TO "authenticated";
GRANT ALL ON TABLE "public"."study_summary_entitlements" TO "service_role";



GRANT ALL ON TABLE "public"."study_summary_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."study_summary_orders" TO "service_role";
GRANT INSERT ON TABLE "public"."study_summary_orders" TO "anon";



GRANT ALL ON TABLE "public"."study_summary_package_items" TO "anon";
GRANT ALL ON TABLE "public"."study_summary_package_items" TO "authenticated";
GRANT ALL ON TABLE "public"."study_summary_package_items" TO "service_role";



GRANT ALL ON TABLE "public"."study_summary_packages" TO "anon";
GRANT ALL ON TABLE "public"."study_summary_packages" TO "authenticated";
GRANT ALL ON TABLE "public"."study_summary_packages" TO "service_role";



GRANT ALL ON TABLE "public"."study_summary_questions" TO "authenticated";
GRANT ALL ON TABLE "public"."study_summary_questions" TO "service_role";



GRANT ALL ON TABLE "public"."subjects" TO "anon";
GRANT ALL ON TABLE "public"."subjects" TO "authenticated";
GRANT ALL ON TABLE "public"."subjects" TO "service_role";



GRANT ALL ON TABLE "public"."system_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."system_settings" TO "service_role";
GRANT SELECT ON TABLE "public"."system_settings" TO "anon";



GRANT ALL ON TABLE "public"."tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."tasks" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







