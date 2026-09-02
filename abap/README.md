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
| `P_TRKORR` | Customizing request for the save popup (blank = no popup expected) |
| `P_EXIT` | Append the screens that leave the transaction after the save |

Start with `P_TEST`, then `P_CALL` with `P_MODE = 'A'` on a single row to
confirm the recording still matches your release, then switch to `'N'`
for the mass run. For a large file `P_SESS` is the safer option — every
failing transaction stays in `SM35` and can be reprocessed.

Text symbols to maintain: `TEXT-001` (*File*), `TEXT-002`
(*Processing*), `TEXT-003` (*BDC end of transaction*).

## Scope

- Existing special rules are reported and skipped; the recording
  supports INSERT only.
- `TFAIN` / `TFAIT` are read for the status columns only — they are
  never modified directly.
- The screen sequence is release-dependent. If `CALL TRANSACTION` stops
  on an unexpected screen, re-record in `SHDB` and replace the
  `bdc_dynpro` / `bdc_field` block in `FORM build_bdc`.

## Troubleshooting

### `SY-SUBRC = 1001` in background, foreground stops at the save

Batch input does not stop when the data is **saved**, it stops when the
**transaction ends**. If the BDC data runs out while a screen is still
active, `CALL TRANSACTION` terminates with `SY-SUBRC = 1001`; in the
foreground (`P_MODE = 'A'`/`'E'`) there is nothing left to feed the
screen, so the run just halts there and waits for you.

The original recording ended on `=SAVE`. Everything SCAL still shows
after that had no BDC data, which produces exactly those two symptoms.
`FORM build_bdc_tail` now supplies it:

1. **Prompt for Customizing request** (`SAPLSTRD` screen `0300`). The
   factory calendar is cross-client Customizing, so a client that
   records changes asks for a transport request on save — and a
   background job cannot answer it. Enter the request in `P_TRKORR`.
   If your client does *not* record changes the popup is never raised
   and `P_TRKORR` must stay empty, otherwise the extra screen becomes
   the mismatch.
2. **The way back out** — `0210` → `0200` → the calendar list → `0100`,
   controlled by `P_EXIT`.

The screen numbers and OK codes in that tail are release-dependent and
are a best guess. Verify them against your own recording.

### Finding the screen it actually stopped on

The result list has a **Stopped on** column. It is filled from message
`00 344` *"No batch input data for screen &1 &2"*, which names the
program and dynpro that had no data — that is the screen to add to
`build_bdc_tail`.

The earlier version collected only `E`/`A`/`X` messages. Message
`00 344` is a status message, so it was discarded and all you saw was
the bare return code. All messages are now kept, and any failure
without an error message reports them with their type.

### Getting the recording right

`SHDB` is the ground truth. Record from the SCAL start screen all the
way through to **leaving the transaction** — do not stop at the save,
green-arrow back out until you are on the SAP menu. Then replace the
`bdc_dynpro` / `bdc_field` blocks in `build_bdc` and `build_bdc_tail`
with what was recorded.

### For background runs, prefer the session

`P_SESS` writes a batch input session instead of calling the
transaction. Process it in `SM35` with *Display errors only*: when a
screen has no data the session stops and shows it to you, you complete
it by hand, and the screen you had to fill in is the one missing from
the program. It is also the safer option for a large file — every
failing transaction stays in the session and can be reprocessed,
whereas `CALL TRANSACTION` in a background job with a popup it cannot
answer will fail every single row the same way.
