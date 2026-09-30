# Changelog

## 0.3.2

### Fixed

- Moving a record between owners now recounts the old owner when `belongs_to` uses a custom
  `primary_key:`.
- Polymorphic `belongs_to` with custom `foreign_key:`/`foreign_type:` no longer raises
  `NoMethodError` on save.
- Moving a record away from a polymorphic type whose class no longer exists no longer raises
  `NameError`; the new owner is still recounted.
- With `includes(:counters)`, counters stay current after an update, and a missing counter
  returns 0 without a query.
- Two saves creating the same virtual counter at once no longer fail with
  `ActiveRecord::RecordNotUnique`; the second updates the row instead.
- `update_counter_cache` without its `belongs_to` raises a clear `ArgumentError` instead of
  `NoMethodError ... for nil`.

### Changed

- Depend on `activerecord` and `activesupport` instead of all of `rails`.
- Require Ruby >= 3.1 in the gemspec, matching the README and Rails 7.2.
- Test against every non-EOL Ruby (3.3, 3.4, 4.0) and Rails (8.0, 8.1).
- Expand the test suite to cover all branches.
- README: fix the `:if` example (`state_changed?` is always false in after callbacks)
  and note that `:if` also applies to `after_destroy`.
