-- Al-Khair Academy ERP, release 1: starting reference data.
-- Everything here can be edited later by the owner.

insert into public.school_settings (id, school_name) values (true, 'Al-Khair Academy')
on conflict (id) do nothing;

insert into public.academic_years (label, starts_on, ends_on, is_current)
values ('2026-27', '2026-04-01', '2027-03-31', true);

insert into public.classes (name, sort_order) values
  ('Nursery', 0), ('LKG', 1), ('UKG', 2),
  ('Class 1', 3), ('Class 2', 4), ('Class 3', 5), ('Class 4', 6),
  ('Class 5', 7), ('Class 6', 8), ('Class 7', 9), ('Class 8', 10);

insert into public.accounts (code, name, type, is_system) values
  -- assets
  ('1010', 'Cash in hand',                    'asset', true),
  ('1020', 'Bank accounts',                   'asset', true),
  ('1100', 'Fee receivable',                  'asset', true),
  ('1200', 'Advances and deposits',           'asset', false),
  ('1500', 'Furniture and equipment',         'asset', false),
  ('1510', 'Building and land',               'asset', false),
  ('1590', 'Accumulated depreciation',        'asset', false),
  -- liabilities
  ('2000', 'Fees received in advance',        'liability', false),
  ('2100', 'Salary payable',                  'liability', false),
  ('2200', 'Other payables',                  'liability', false),
  ('2300', 'Loans',                           'liability', false),
  -- equity
  ('3000', 'Opening balance equity',          'equity', true),
  ('3100', 'School fund',                     'equity', false),
  -- income
  ('4010', 'Tuition fees',                    'income', true),
  ('4020', 'Admission fees',                  'income', true),
  ('4030', 'Annual charges',                  'income', true),
  ('4040', 'Transport fees',                  'income', true),
  ('4050', 'Exam fees',                       'income', true),
  ('4060', 'Other fees and fines',            'income', true),
  ('4100', 'Donations',                       'income', false),
  ('4200', 'Other income',                    'income', false),
  ('4900', 'Fee concessions (deduction)',     'income', true),
  -- expenses
  ('5010', 'Salaries and wages',              'expense', false),
  ('5020', 'Rent',                            'expense', false),
  ('5030', 'Electricity and water',           'expense', false),
  ('5040', 'Stationery and printing',         'expense', false),
  ('5050', 'Repairs and maintenance',         'expense', false),
  ('5060', 'Transport and fuel',              'expense', false),
  ('5070', 'Marketing and admissions',        'expense', false),
  ('5080', 'Books and teaching material',     'expense', false),
  ('5090', 'Events and activities',           'expense', false),
  ('5100', 'Software and internet',           'expense', false),
  ('5110', 'Bank charges',                    'expense', false),
  ('5120', 'Depreciation',                    'expense', false),
  ('5200', 'Miscellaneous expenses',          'expense', false);

insert into public.fee_heads (code, name, income_account_id)
select h.code, h.name, a.id
  from (values
    ('TUITION',   'Tuition fee',     '4010'),
    ('ADMISSION', 'Admission fee',   '4020'),
    ('ANNUAL',    'Annual charges',  '4030'),
    ('TRANSPORT', 'Transport fee',   '4040'),
    ('EXAM',      'Exam fee',        '4050'),
    ('OTHER',     'Other fees',      '4060')
  ) as h(code, name, acc)
  join public.accounts a on a.code = h.acc;

insert into public.document_types (code, name, required_from_order) values
  ('birth_certificate',    'Birth certificate',                  0),
  ('student_aadhaar',      'Aadhaar card (student)',             0),
  ('parent_id',            'Parent or guardian ID proof',        0),
  ('photographs',          'Passport size photographs',          0),
  ('address_proof',        'Address proof',                      0),
  ('health_card',          'Vaccination or health card',         0),
  ('previous_marksheet',   'Previous class marksheet',           3),
  ('transfer_certificate', 'Transfer certificate (TC)',          3);
