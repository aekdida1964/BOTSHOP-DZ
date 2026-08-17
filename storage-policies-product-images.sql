-- ============================================================================
-- سياسات مساحة تخزين صور المنتجات (product-images)
-- الفكرة: كل صورة تُرفع داخل مجلد باسم معرّف المتجر (store_id) كمسار،
-- مثال: 3fae1c9b-xxxx-xxxx/hzuka1.jpg
-- هذا يسمح بالتحقق تلقائياً أن الرافع هو فعلاً صاحب ذلك المتجر
-- ============================================================================

-- 1) القراءة: مسموحة للجميع (الزوار يشاهدون صور المنتجات في المتجر العام)
create policy "product_images_public_read"
on storage.objects for select
using (bucket_id = 'product-images');

-- 2) الرفع: مسموح فقط لصاحب المتجر داخل مجلد متجره
create policy "product_images_insert_own_store"
on storage.objects for insert
with check (
  bucket_id = 'product-images'
  and exists (
    select 1 from public.stores s
    where s.id::text = (storage.foldername(name))[1]
      and s.owner_id = auth.uid()
  )
);

-- 3) التعديل/الاستبدال: نفس الشرط
create policy "product_images_update_own_store"
on storage.objects for update
using (
  bucket_id = 'product-images'
  and exists (
    select 1 from public.stores s
    where s.id::text = (storage.foldername(name))[1]
      and s.owner_id = auth.uid()
  )
);

-- 4) الحذف: نفس الشرط
create policy "product_images_delete_own_store"
on storage.objects for delete
using (
  bucket_id = 'product-images'
  and exists (
    select 1 from public.stores s
    where s.id::text = (storage.foldername(name))[1]
      and s.owner_id = auth.uid()
  )
);
