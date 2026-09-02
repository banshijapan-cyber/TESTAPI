# ZFC_UPLOAD_SPECIAL_RULE

Uploads factory calendar special rules from Excel into SCAL via BDC.

Source: [`zfc_upload_special_rule.prog.abap`](zfc_upload_special_rule.prog.abap)

## Why the dates came out as `00000000`

`FORM convert_date` validated the digits like this:

```abap
DATA lv_value TYPE char255.
...
CONDENSE lv_value NO-GAPS.        " -> '20270103' + 247 blanks
IF strlen( lv_value ) <> 8.       " passes, STRLEN ignores blanks
  RETURN.
ENDIF.
IF lv_value CO '0123456789'.      " always FALSE
  " ...
ELSE.
  RETURN.                         " <- every row left here
ENDIF.
```

`CO` (and `CN`, `CA`, `NA`) compare the **whole field including trailing
blanks**, unlike `CS`/`CP` which ignore them. A `CHAR255` field holding
`20270103` therefore never "contains only" digits, the check failed for
perfectly valid input, `CV_DATE` was never filled, and the caller saw
`00000000`.

The corrected version copies the value into a `CHAR8` field that is
completely filled before checking it, so there are no trailing blanks
left to trip over.

## Other defects fixed

| Area | Problem | Fix |
| --- | --- | --- |
| `execute_scal_bdc` | On a BDC failure the error text was written to `gt_result INDEX lines( gt_result )` — but the current row had not been appended yet, so the message landed on the **previous** row. | The message is returned through a `CHANGING` parameter and assigned to the row it belongs to. |
| BDC result check | Success was taken from `SY-SUBRC` alone; a transaction that ends cleanly after collecting an `E` message would be reported as *Created*. | Success requires `SY-SUBRC = 0` **and** no `E`/`A`/`X` message in `BDCMSGCOLL`. |
| `SELECT` statements | `WHERE jahr = @gs_input-date_from+0(4)` — offset/length on a host variable is not allowed in ABAP SQL and is a syntax error on current releases. | The year is moved into `lv_jahr` first. |
| `build_input` | `AT NEW row` / `AT END OF row` overwrite the work-area components behind the control field with `*`, which makes the construct fragile here. | Explicit row-break handling. |
| `convert_date_external` | The fallback hard-coded `YYYY.MM.DD`. A BDC date in the wrong format is rejected by the screen. | The fallback builds the string from the user's `USR01-DATFM`. |
| Excel values | A numeric cell can arrive as `20270103.0`, and users paste `2027-01-03`. | The fraction is dropped and `.`, `/`, `-` are stripped before validation. |
| Processing mode | `MODE 'E'` was hard-coded ("intentionally while testing"). | Selection-screen parameters for display mode, update mode, and a batch-input-session alternative. |
| Row validation | Rows with an unconvertible date were silently reported as "blank". | The conversion error text is carried into the ALV. |

## Known gap: the workday flag

Column D of the template is read and shown in the ALV, but the recording
in this program (`SZC_FACTORY_CALENDAR_MAINTAIN` screen `0215`) only
fills `TIFAB-DATUMVON`, `TIFAB-DATUMBIS` and `TFAIT-LTEXT`. It never
touches the workday / non-workday indicator, so every rule is created
with the screen default.

To close it:

1. In `SHDB`, record one special rule **with** "Workday" set and one
   without it.
2. Diff the two recordings and take the field name that differs.
3. Put it into `gc_fld_workday` at the top of the program.

Until then the ALV flags any row with `Workday = X` as a `WARNING`, in
both simulation and update runs, so the gap is visible rather than
silent.

## Excel template

Row 1 is a header (configurable via *Header rows*), data starts in row 2.

| A | B | C | D | E |
| --- | --- | --- | --- | --- |
| Calendar ID | From Date | To Date | Workday | Text |
| `A1` | `20270103` | `20270103` | `X` | `Special Holiday BDC` |

- Dates are `YYYYMMDD`. Format the column as **text** in Excel so the
  leading value is not turned into a number.
- To Date may be left blank — it then defaults to From Date.
- From Date and To Date must fall in the same year.
- `ALSM_EXCEL_TO_INTERNAL_TABLE` truncates a cell at 50 characters, so
  the text column is limited to 50 even though `TFAIT-LTEXT` holds 60.

## Selection screen

| Parameter | Meaning |
| --- | --- |
| `P_FILE` | Excel file (`.xls`/`.xlsx`) |
| `P_HDR` | Number of header rows to skip (default 1) |
| `P_TEST` | Simulation — validates and reports, runs no BDC |
| `P_CALL` | Update via `CALL TRANSACTION` |
| `P_SESS` | Update via batch input session (process in `SM35`) |
| `P_MODE` | Display mode for `CALL TRANSACTION`: `A` / `E` / `N` |
| `P_UPDT` | Update mode: `S` synchronous, `A` asynchronous, `L` local |
| `P_GROUP` | Batch input session name |

Start with `P_TEST`, then `P_CALL` with `P_MODE = 'A'` on a single row to
confirm the recording still matches your release, then switch to `'N'`
for the mass run. For a large file `P_SESS` is the safer option — every
failing transaction stays in `SM35` and can be reprocessed.

Text symbols to maintain: `TEXT-001` (*File*), `TEXT-002` (*Processing*).

## Scope

- Existing special rules are reported and skipped; the recording
  supports INSERT only.
- `TFAIN` / `TFAIT` are read for the status columns only — they are
  never modified directly.
- The screen sequence is release-dependent. If `CALL TRANSACTION` stops
  on an unexpected screen, re-record in `SHDB` and replace the
  `bdc_dynpro` / `bdc_field` block in `FORM build_bdc`.
