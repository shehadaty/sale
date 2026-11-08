-- ============================================================================
-- Migration 5: إعدادات الهوية (White Label) في system_settings.
-- * قيم افتراضية محايدة لعميل جديد (تُعدَّل من إعدادات النظام أو SQL). ON CONFLICT DO NOTHING
--   فلا تُكتب فوق قيم موجودة.
-- * قراءة anon مقصورة على مفاتيح العرض العام فقط (اسم، ألوان، تواصل). لا مفاتيح داخلية.
-- لم تُجرَّب على قاعدة فعلية بعد.
-- ============================================================================
INSERT INTO public.system_settings (key, value) VALUES
  ('system_name',           'أكاديمية النموذج'),
  ('academy_short_name',    'النموذج'),
  ('academy_director_name', 'مدير الأكاديمية'),
  ('academy_logo_url',      ''),
  ('brand_navy',            '#152238'),
  ('brand_navy2',           '#1f3562'),
  ('brand_gold',            '#c9a24c'),
  ('brand_gold2',           '#e8c87a'),
  ('contact_phone',         ''),
  ('contact_whatsapp',      ''),
  ('contact_email',         ''),
  ('contact_address',       ''),
  ('social_facebook',       ''),
  ('social_instagram',      ''),
  ('social_youtube',        ''),
  ('social_tiktok',         '')
ON CONFLICT (key) DO NOTHING;

DROP POLICY IF EXISTS "system_settings_public_display_read" ON public.system_settings;
CREATE POLICY "system_settings_public_display_read" ON public.system_settings
  FOR SELECT TO anon
  USING (key = ANY (ARRAY[
    'system_name','whatsapp_news_link','academy_short_name','academy_director_name','academy_logo_url',
    'brand_navy','brand_navy2','brand_gold','brand_gold2',
    'contact_phone','contact_whatsapp','contact_email','contact_address',
    'social_facebook','social_instagram','social_youtube','social_tiktok'
  ]));
