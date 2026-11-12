-- ميثاق الأداء: البيانات الأولية (تُنفَّذ بعد schema.sql على قاعدة بيانات جديدة)
-- المعادلة والإعدادات كما اعتُمدت لسنة 2027، وقائمة الأسماء.
-- لا يحتوي هذا الملف على أي رقم سري أو رمز مدير ولا على أعمال مرسلة.
-- بعد التنفيذ: أول رمز يُكتب في «دخول المدير» يصبح رمز المدير،
-- ثم يولّد المدير الأرقام الأولية من تبويب «الأعضاء».

insert into public.m_config(key, data) values ('main', $cfg$
{
  "year": 2027,
  "maxScore": 5,
  "workDays": 241,
  "opsTarget": 2410,
  "opsWeight": 0.00104,
  "qualityTarget": 100,
  "showWeights": false,
  "sendOpenDays": 3,
  "sendGraceDays": 5,
  "sendAlways": false,
  "bands": [
    {
      "from": 0,
      "label": "غير مرضي"
    },
    {
      "from": 1.5,
      "label": "يحتاج لتطوير"
    },
    {
      "from": 2.5,
      "label": "وافق التوقعات"
    },
    {
      "from": 3.5,
      "label": "فاق التوقعات"
    },
    {
      "from": 4.5,
      "label": "مثالي"
    }
  ],
  "groups": [
    {
      "id": "g1",
      "label": "الضبطيات",
      "t": 4
    }
  ],
  "axes": [
    {
      "id": "vis",
      "name": "الزيارات",
      "quality": true,
      "qt": 98,
      "fields": [
        {
          "id": "v1",
          "label": "زيارات البلاغ"
        },
        {
          "id": "v2",
          "label": "الزيارات التصحيحية"
        },
        {
          "id": "v3",
          "label": "المهام المسندة"
        },
        {
          "id": "v4",
          "label": "الجولات الوزارية"
        },
        {
          "id": "v5",
          "label": "الزيارات التموينية"
        }
      ]
    },
    {
      "id": "rep",
      "name": "البلاغات",
      "quality": true,
      "qt": 95,
      "fields": [
        {
          "id": "b1",
          "label": "بلاغات الرقابة التجارية"
        },
        {
          "id": "b2",
          "label": "بلاغات الغش التجاري"
        },
        {
          "id": "b3",
          "label": "بلاغات المعادن"
        },
        {
          "id": "b6",
          "label": "بلاغات سلامة المنتجات"
        },
        {
          "id": "b5",
          "label": "بلاغات المتاجر الإلكترونية"
        },
        {
          "id": "b4",
          "label": "بلاغات الوكالات التجارية"
        }
      ]
    },
    {
      "id": "rd",
      "name": "القراءات التموينية",
      "quality": false,
      "fields": [
        {
          "id": "r1",
          "label": "القراءات التموينية",
          "w": 5e-05,
          "t": 9600
        }
      ]
    },
    {
      "id": "cs",
      "name": "القضايا والمنتجات المضبوطة",
      "quality": false,
      "fields": [
        {
          "id": "c1",
          "label": "عدد القضايا لغير المنتجات",
          "w": 0.1,
          "g": "g1"
        },
        {
          "id": "p1",
          "label": "المنتجات المضبوطة",
          "w": 0.0001225
        },
        {
          "id": "c2",
          "label": "قضايا المتاجر والوكالات",
          "w": 0.02,
          "g": "g1"
        }
      ]
    }
  ]
}
$cfg$::jsonb)
on conflict (key) do update set data = excluded.data, updated_at = now();

insert into public.m_people(id, name, role, supervisor_id, sort) values
  ('s01', 'حسين راجحي', 'supervisor', null, 0),
  ('p01', 'عبدالله كيلاني', 'employee', 's01', 1),
  ('p02', 'عبدالعزيز قمعي', 'employee', 's01', 2),
  ('p03', 'عبدالله دهل القحطاني', 'employee', 's01', 3),
  ('p04', 'هادي حسين طوهري', 'employee', 's01', 4),
  ('p05', 'مجاهد ابو جبل', 'employee', 's01', 5),
  ('p06', 'عبدالكريم شوك', 'employee', 's01', 6),
  ('p07', 'عبدالله السبيعي', 'employee', 's01', 7),
  ('p08', 'خديجة زيدي', 'employee', 's01', 8),
  ('p09', 'احمد حسين خواجي', 'employee', 's01', 9),
  ('p10', 'محمد دغريري', 'employee', 's01', 10),
  ('p11', 'عماد حنبشي', 'employee', 's01', 11),
  ('p12', 'نظام الدين مقبول', 'employee', 's01', 12),
  ('p13', 'عثمان حمادي', 'employee', 's01', 13),
  ('p14', 'ابراهيم دايلي', 'employee', 's01', 14),
  ('p15', 'محمد قاسم ظلام', 'employee', 's01', 15),
  ('p16', 'حسن هزازي', 'employee', 's01', 16),
  ('p17', 'خالد عريشي', 'employee', 's01', 17),
  ('p18', 'حسن صلوي', 'employee', 's01', 18),
  ('p19', 'علي ابو شملة', 'employee', 's01', 19),
  ('p20', 'صالحه عواجي', 'employee', 's01', 20),
  ('p21', 'يحي غزواني', 'employee', 's01', 21),
  ('p22', 'هديل محمد فارس', 'employee', 's01', 22),
  ('p23', 'محمد مجلي', 'employee', 's01', 23),
  ('p24', 'احمد بريك', 'employee', 's01', 24)
on conflict (id) do update set name = excluded.name, role = excluded.role, supervisor_id = excluded.supervisor_id, sort = excluded.sort;
