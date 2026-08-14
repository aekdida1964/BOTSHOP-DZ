/* ============================================================================
   BOTSHOP-DZ — إعداد Supabase المشترك
   يجب تضمين مكتبة supabase-js عبر CDN قبل هذا الملف في كل صفحة تستعمله:
   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
   <script src="supabase-config.js"></script>
   ============================================================================ */

const SUPABASE_URL = 'https://nqqjwqbepridkhvrozpt.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5xcWp3cWJlcHJpZGtodnJvenB0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY2MjE1NDksImV4cCI6MjEwMjE5NzU0OX0.srqX8GTYRpxSFC3AF8G5c4Vc_oFkffVtjaqrVt7cmDY';

// عميل Supabase — يُستعمل في كل الصفحات عبر المتغير sb
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// إلى أي صفحة يُعاد توجيه كل دور بعد الدخول
function redirectPathForRole(role) {
  if (role === 'admin') return '03-admin.html';
  if (['supplier', 'retailer', 'contracted'].includes(role)) return '05-merchant-dashboard.html';
  return '01-landing.html'; // customer / founder / influencer — لا توجد لوحة خاصة بعد
}

/**
 * يتحقق من وجود جلسة دخول صالحة، ومن أن دور المستخدم ضمن الأدوار المسموحة.
 * يُستدعى في بداية كل صفحة محمية. يُعيد { session, profile } أو null بعد إعادة التوجيه.
 * @param {string[]|null} allowedRoles - مثال: ['admin'] أو ['supplier','retailer','contracted']. null = أي مستخدم مسجّل دخول.
 */
async function requireAuth(allowedRoles = null) {
  const { data: { session } } = await sb.auth.getSession();

  if (!session) {
    location.href = '02-auth.html';
    return null;
  }

  const { data: profile, error } = await sb
    .from('profiles')
    .select('*')
    .eq('id', session.user.id)
    .single();

  if (error || !profile) {
    // جلسة موجودة لكن لا يوجد ملف تعريف مرتبط بها — حالة غير متوقعة، نعيد تسجيل الدخول
    await sb.auth.signOut();
    location.href = '02-auth.html';
    return null;
  }

  if (allowedRoles && !allowedRoles.includes(profile.role)) {
    alert('ليست لديك صلاحية الوصول لهذه الصفحة.');
    location.href = redirectPathForRole(profile.role);
    return null;
  }

  return { session, profile };
}

// تسجيل الخروج وإعادة التوجيه لصفحة الدخول — يُستدعى من زر "تسجيل الخروج" في اللوحات
async function signOutAndRedirect() {
  await sb.auth.signOut();
  location.href = '02-auth.html';
}
