# التصويت المباشر 🗳️

تطبيق ويب عربي للتصويت من عدة أجهزة: يعرض الخيارات، يسجّل صوتًا واحدًا لكل متصفح، ويعرض النتائج مباشرة لكل من يملك الرابط. لا يحتاج المصوّتون إلى إيميل أو تسجيل؛ يتم إنشاء جلسة مجهولة تلقائيًا عند أول تصويت.

**النسخة المباشرة:** https://mrthnr67.github.io/tournament-bracket/

## المميزات

- واجهة عربية RTL متجاوبة مع الجوال واللابتوب.
- تصويت من أي جهاز عبر الرابط نفسه، بدون تطبيق أو تسجيل.
- صوت واحد لكل متصفح (جلسة مجهولة)، ومنع تكرار الإرسال.
- نتائج مباشرة تتحدث تلقائيًا كل 5 ثوانٍ.
- دعم اختيار واحد أو أكثر لكل مصوّت عبر `max_choices`.
- زر تحديث يدوي، وحالة الاتصال، وعدّاد المشاركين وإجمالي الأصوات.
- صفحة البطولة القديمة (خروج مغلوب) ما زالت متاحة على `tournament.html`.

## التشغيل محلياً

```bash
npx serve .
```

ثم افتح `http://localhost:3000/`.

## إعداد Supabase

المشروع مربوط بـ Supabase:

- **Project URL:** `https://tgrrpgrnctgpgjftlnti.supabase.co`
- **Publishable Key:** موجود داخل `index.html` (مفتاح عام آمن للواجهة).
- **Anonymous Sign-Ins:** مفعّل من `Authentication → Providers → Anonymous Sign-Ins`.
- **المخطط الكامل:** موجود في `supabase.sql` ويمكن لصقه في SQL Editor لإعادة الإنشاء.

### تغيير عنوان التصويت

من **SQL Editor**:

```sql
update voting_data.settings
set title = 'تصويت الأسماء'
where singleton;
```

### تغيير أسماء الخيارات

الأسماء الحالية تجريبية. بدّلها من **SQL Editor**:

```sql
update voting_data.choices set label = 'الاسم الأول' where id = 1;
update voting_data.choices set label = 'الاسم الثاني' where id = 2;
update voting_data.choices set label = 'الاسم الثالث' where id = 3;
update voting_data.choices set label = 'الاسم الرابع' where id = 4;
update voting_data.choices set label = 'الاسم الخامس' where id = 5;
update voting_data.choices set label = 'الاسم السادس' where id = 6;
```

لإضافة خيار جديد، أضف صفًا برقم جديد:

```sql
insert into voting_data.choices (id, label)
values (7, 'الاسم السابع');
```

### السماح باختيارين كحد أقصى

```sql
update voting_data.settings set max_choices = 2 where singleton;
```

أعدها إلى `1` للسماح بخيار واحد فقط:

```sql
update voting_data.settings set max_choices = 1 where singleton;
```

### فتح أو إغلاق التصويت

```sql
update voting_data.settings set is_open = false where singleton; -- إغلاق
update voting_data.settings set is_open = true  where singleton; -- فتح
```

### تصفير الأصوات قبل النشر أو لبدء تصويت جديد

```sql
delete from voting_data.ballots;
update voting_data.settings set version = version + 1 where singleton;
```

سيتم حذف الاختيارات المرتبطة تلقائيًا بسبب `on delete cascade`. زيادة `version` تسمح للمصوّتين السابقين بالتصويت مجددًا في التصويت الجديد، لأن الواجهة تخزّن علامة "تم التصويت" مرتبطة برقم النسخة.

### عرض النتائج من SQL Editor

```sql
select public.get_voting_state();
```

## ملاحظة عن الخصوصية

التصويت المجهول يمنع تكرار الصوت من نفس جلسة المتصفح. من يمسح بيانات الموقع أو يستخدم متصفحًا آخر يمكنه التصويت مرة أخرى؛ هذا قيد inherent في التصويت المجهول. إذا احتجت منعًا صارمًا (صوت واحد لكل شخص)، استخدم تسجيل الدخول بالبريد/OTP أو قائمة أسماء مسموح لها بالتصويت.

## البنية

| الملف | الوظيفة |
|---|---|
| `index.html` | تطبيق التصويت المباشر (HTML + CSS + JavaScript + Supabase) |
| `supabase.sql` | مخطط قاعدة البيانات والدوال وسياسات الوصول |
| `tournament.html` | تطبيق بطولة الخروج المغلوب القديم (بدون خادم) |
| `render.yaml` | إعداد نشر ثابت اختياري على Render |
| `og.jpg` | صورة مشاركة صفحة التصويت |
| `og-tournament.jpg` | صورة مشاركة صفحة البطولة |

## النشر

الموقع منشور عبر **GitHub Pages** من فرع `main` في المستودع:

https://github.com/MrTHNR67/tournament-bracket

أي تعديل على `index.html` يُرفع إلى `main` وينتشر خلال دقيقة تقريبًا.

### Render (اختياري)

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/MrTHNR67/tournament-bracket)

## قاعدة البيانات

- `voting_data.settings`: العنوان، `max_choices`، وحالة الفتح.
- `voting_data.choices`: الخيارات وأرقامها.
- `voting_data.ballots`: جلسات المصوّتين (صوت واحد لكل جلسة).
- `voting_data.selections`: الخيارات التي اختارها كل مصوّت.
- `public.get_voting_state()`: يرجع الحالة والنتائج للواجهة.
- `public.submit_voting_ballot(choice_ids integer[])`: يسجّل الصوت بعد التحقق من الجلسة والعدد والحالة.
- RLS مفعّل، والوصول للجداول محجوب؛ الواجهة تستخدم الدالتين فقط.
