*&---------------------------------------------------------------------*
*& Report  ZFC_UPLOAD_SPECIAL_RULE
*&---------------------------------------------------------------------*
*& Upload Factory Calendar Special Rules using SCAL BDC.
*&
*& Excel template (row 1 = header, data starts in row 2):
*&
*&   Column A = Calendar ID
*&   Column B = From Date   YYYYMMDD
*&   Column C = To Date     YYYYMMDD
*&   Column D = Workday     X = working day, blank = non-working
*&   Column E = Text
*&
*& Example:
*&
*&   A1 | 20270103 | 20270103 | X | Special Holiday BDC
*&
*& Notes:
*&   - Simulation checks existing entries only.
*&   - No direct MODIFY of TFAIN / TFAIT.
*&   - The update is performed through the SCAL BDC recording.
*&   - The recording supports INSERT only; existing special rules
*&     are reported and skipped.
*&
*& The BDC has to drive SCAL until the transaction ENDS, not until the
*& data is saved. If the BDC data runs out while a screen is still
*& active, CALL TRANSACTION terminates with SY-SUBRC = 1001 (in the
*& foreground the run simply stops on that screen and waits). The tail
*& in FORM BUILD_BDC_TAIL covers the information popup raised on save
*& and the way back out of the transaction - verify it against your own
*& SHDB recording, which must be recorded through to leaving SCAL.
*&
*& The popup's program and screen are entered on the selection screen
*& (P_PPROG / P_PDYNP, defaulted from the recording); the result list
*& reports them in "Stopped on" if they ever differ.
*&
*& Saving does NOT prompt for a Customizing request - the calendar is
*& not covered by automatic recording of changes and has its own
*& transport connection (Calendar -> Transport on the SCAL initial
*& screen). That is a separate manual step after the upload.
*&---------------------------------------------------------------------*

REPORT zfc_upload_special_rule.

*---------------------------------------------------------------------*
* Constants
*---------------------------------------------------------------------*
CONSTANTS:
  gc_tcode       TYPE tcode        VALUE 'SCAL',

* Cursor positions in the calendar list (SAPMSSY0 0120). The second one
* decides which line =UPDA opens in change mode, so it has to point at
* the single data line the calendar ID filter leaves behind.
  gc_cur_unfiltered TYPE char10 VALUE '02/05',
  gc_cur_filtered   TYPE char10 VALUE '04/03'.

*---------------------------------------------------------------------*
* Selection screen
*---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE text-001.

PARAMETERS:
  p_file TYPE rlgrap-filename OBLIGATORY,
  p_hdr  TYPE i DEFAULT 1.

SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE text-002.

PARAMETERS:
  p_test RADIOBUTTON GROUP r1 DEFAULT 'X' USER-COMMAND uc1,
  p_call RADIOBUTTON GROUP r1,
  p_sess RADIOBUTTON GROUP r1.

PARAMETERS:
  p_mode  TYPE ctu_params-dismode DEFAULT 'N' MODIF ID cal,
  p_updt  TYPE ctu_params-updmode DEFAULT 'S' MODIF ID cal,
  p_group TYPE apqi-groupid       DEFAULT 'ZFC_SPRUL' MODIF ID ses.

SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE text-003.

PARAMETERS:
  p_rec200 AS CHECKBOX,
  p_pprog TYPE bdcdata-program DEFAULT 'SAPMSSY0',
  p_pdynp TYPE bdcdata-dynpro  DEFAULT '0120',
  p_pokcd TYPE char20          DEFAULT '=DBAC',
  p_exit  AS CHECKBOX DEFAULT 'X'.

SELECTION-SCREEN END OF BLOCK b3.

*---------------------------------------------------------------------*
* Excel raw data
*---------------------------------------------------------------------*
TYPES:
  BEGIN OF ty_excel,
    row   TYPE i,
    col   TYPE i,
    value TYPE char255,
  END OF ty_excel.

DATA:
  gt_excel TYPE STANDARD TABLE OF ty_excel,
  gs_excel TYPE ty_excel.

*---------------------------------------------------------------------*
* Input data
*---------------------------------------------------------------------*
TYPES:
  BEGIN OF ty_input,
    excel_row TYPE i,
    ident     TYPE tfain-ident,
    date_from TYPE sy-datum,
    date_to   TYPE sy-datum,
    workday   TYPE c LENGTH 1,
    wert      TYPE c LENGTH 1,
    text      TYPE tfait-ltext,
    error     TYPE char255,
  END OF ty_input.

DATA:
  gt_input TYPE STANDARD TABLE OF ty_input,
  gs_input TYPE ty_input.

*---------------------------------------------------------------------*
* Result
*---------------------------------------------------------------------*
TYPES:
  BEGIN OF ty_result,
    excel_row TYPE i,
    ident     TYPE tfain-ident,
    date_from TYPE sy-datum,
    date_to   TYPE sy-datum,
    workday   TYPE c LENGTH 1,
    wert      TYPE c LENGTH 1,
    tfain     TYPE char20,
    tfait_e   TYPE char20,
    tfait_j   TYPE char20,
    action    TYPE char30,
    status    TYPE char20,
    screen    TYPE char40,
    message   TYPE char255,
  END OF ty_result.

DATA:
  gt_result TYPE STANDARD TABLE OF ty_result,
  gs_result TYPE ty_result.

*---------------------------------------------------------------------*
* BDC data
*---------------------------------------------------------------------*
DATA:
  gt_bdcdata TYPE STANDARD TABLE OF bdcdata,
  gs_bdcdata TYPE bdcdata,

  gt_bdcmsg  TYPE STANDARD TABLE OF bdcmsgcoll,
  gs_bdcmsg  TYPE bdcmsgcoll,

  gv_session TYPE abap_bool.

*---------------------------------------------------------------------*
* F4 Help
*---------------------------------------------------------------------*
AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.

  CALL FUNCTION 'F4_FILENAME'
    EXPORTING
      field_name = 'P_FILE'
    IMPORTING
      file_name  = p_file.

*---------------------------------------------------------------------*
* Screen control
*---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.

  LOOP AT SCREEN.

    IF screen-group1 = 'CAL'.
      IF p_call = abap_true.
        screen-input = 1.
      ELSE.
        screen-input = 0.
      ENDIF.
      MODIFY SCREEN.
    ENDIF.

    IF screen-group1 = 'SES'.
      IF p_sess = abap_true.
        screen-input = 1.
      ELSE.
        screen-input = 0.
      ENDIF.
      MODIFY SCREEN.
    ENDIF.

  ENDLOOP.

AT SELECTION-SCREEN.

  IF p_hdr < 0.
    MESSAGE 'Number of header rows cannot be negative.'
      TYPE 'E'.
  ENDIF.

  IF p_call = abap_true
     AND p_mode NA 'AEN'.
    MESSAGE 'Processing mode must be A, E or N.'
      TYPE 'E'.
  ENDIF.

*---------------------------------------------------------------------*
* Main
*---------------------------------------------------------------------*
START-OF-SELECTION.

  PERFORM upload_excel.

  IF gt_excel IS INITIAL.
    MESSAGE 'No Excel data found.'
      TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  PERFORM build_input.

  IF gt_input IS INITIAL.
    MESSAGE 'No valid Excel rows found.'
      TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  PERFORM open_session.

  PERFORM validate_and_process.

  PERFORM close_session.

  PERFORM display_alv.

*---------------------------------------------------------------------*
* Upload Excel
*---------------------------------------------------------------------*
FORM upload_excel.

  DATA:
    lt_raw     TYPE STANDARD TABLE OF alsmex_tabline,
    ls_raw     TYPE alsmex_tabline,
    lv_beg_row TYPE i.

  CLEAR gt_excel.

  lv_beg_row = p_hdr + 1.

  CALL FUNCTION 'ALSM_EXCEL_TO_INTERNAL_TABLE'
    EXPORTING
      filename                = p_file
      i_begin_col             = 1
      i_begin_row             = lv_beg_row
      i_end_col               = 5
      i_end_row               = 99999
    TABLES
      intern                  = lt_raw
    EXCEPTIONS
      inconsistent_parameters = 1
      upload_ole              = 2
      OTHERS                  = 3.

  IF sy-subrc <> 0.
    MESSAGE 'Excel upload failed.'
      TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  LOOP AT lt_raw INTO ls_raw.

    CLEAR gs_excel.

    gs_excel-row   = ls_raw-row.
    gs_excel-col   = ls_raw-col.
    gs_excel-value = ls_raw-value.

    APPEND gs_excel TO gt_excel.

  ENDLOOP.

  SORT gt_excel BY row col.

ENDFORM.

*---------------------------------------------------------------------*
* Build input
*
* Excel:
*   1 = Calendar ID
*   2 = From Date
*   3 = To Date
*   4 = Workday
*   5 = Text
*
* The row break is handled explicitly instead of with AT NEW / AT END
* OF: inside those blocks the work area components behind the control
* field are overwritten with '*', which makes the construct easy to get
* wrong when the cell value is read in the same iteration.
*---------------------------------------------------------------------*
FORM build_input.

  DATA:
    lv_prev_row TYPE i,
    lv_ident    TYPE string,
    lv_from     TYPE string,
    lv_to       TYPE string,
    lv_workday  TYPE string,
    lv_text     TYPE string.

  CLEAR gt_input.

  LOOP AT gt_excel INTO gs_excel.

    IF lv_prev_row IS NOT INITIAL
       AND gs_excel-row <> lv_prev_row.

      PERFORM append_input
        USING lv_prev_row lv_ident lv_from lv_to lv_workday lv_text.

      CLEAR: lv_ident, lv_from, lv_to, lv_workday, lv_text.

    ENDIF.

    lv_prev_row = gs_excel-row.

    CASE gs_excel-col.
      WHEN 1.
        lv_ident = gs_excel-value.
      WHEN 2.
        lv_from = gs_excel-value.
      WHEN 3.
        lv_to = gs_excel-value.
      WHEN 4.
        lv_workday = gs_excel-value.
      WHEN 5.
        lv_text = gs_excel-value.
    ENDCASE.

  ENDLOOP.

* Last row of the file
  IF lv_prev_row IS NOT INITIAL.

    PERFORM append_input
      USING lv_prev_row lv_ident lv_from lv_to lv_workday lv_text.

  ENDIF.

ENDFORM.

*---------------------------------------------------------------------*
* Append one Excel row to the input table
*---------------------------------------------------------------------*
FORM append_input
  USING
    iv_row     TYPE i
    iv_ident   TYPE string
    iv_from    TYPE string
    iv_to      TYPE string
    iv_workday TYPE string
    iv_text    TYPE string.

  DATA:
    lv_ident   TYPE string,
    lv_workday TYPE string,
    lv_error   TYPE char255.

  CLEAR gs_input.

  gs_input-excel_row = iv_row.

*-------------------------------------------------------------------*
* Calendar ID
*-------------------------------------------------------------------*
  lv_ident = iv_ident.

  CONDENSE lv_ident NO-GAPS.
  TRANSLATE lv_ident TO UPPER CASE.

  gs_input-ident = lv_ident.

*-------------------------------------------------------------------*
* From Date
*-------------------------------------------------------------------*
  PERFORM convert_date
    USING    iv_from
    CHANGING gs_input-date_from
             lv_error.

  IF lv_error IS NOT INITIAL.
    gs_input-error = |From Date: { lv_error }|.
  ENDIF.

*-------------------------------------------------------------------*
* To Date
*-------------------------------------------------------------------*
  PERFORM convert_date
    USING    iv_to
    CHANGING gs_input-date_to
             lv_error.

* A blank To Date defaults to the From Date, anything else that fails
* to convert is a real error.
  IF lv_error IS NOT INITIAL
     AND iv_to IS NOT INITIAL
     AND gs_input-error IS INITIAL.
    gs_input-error = |To Date: { lv_error }|.
  ENDIF.

*-------------------------------------------------------------------*
* Workday
*-------------------------------------------------------------------*
  lv_workday = iv_workday.

  CONDENSE lv_workday NO-GAPS.
  TRANSLATE lv_workday TO UPPER CASE.

  IF lv_workday = 'X'
     OR lv_workday = '1'
     OR lv_workday = 'YES'.
    gs_input-workday = 'X'.
    gs_input-wert    = '1'.
  ELSE.
    CLEAR gs_input-workday.
    gs_input-wert = '0'.
  ENDIF.

*-------------------------------------------------------------------*
* Text
*-------------------------------------------------------------------*
  gs_input-text = iv_text.

* An entirely empty line is not an error, it is simply not data.
  IF gs_input-ident     IS INITIAL
     AND gs_input-date_from IS INITIAL
     AND gs_input-date_to   IS INITIAL
     AND gs_input-text      IS INITIAL.
    RETURN.
  ENDIF.

  APPEND gs_input TO gt_input.

ENDFORM.

*---------------------------------------------------------------------*
* Convert a fixed YYYYMMDD template value into SY-DATUM
*
* This is where the original program returned 00000000 for every row:
*
*   DATA lv_value TYPE char255.
*   ...
*   IF lv_value CO '0123456789'.
*
* CO / CN / CA / NA compare the *whole* field, trailing blanks
* included - unlike CS / CP, which ignore them. '20270103' in a
* CHAR255 field therefore never consists only of digits, the check
* failed for valid input, and the FORM left CV_DATE cleared.
*
* The digit check below runs on a CHAR8 field that is completely
* filled, so there are no trailing blanks left to trip over.
*---------------------------------------------------------------------*
FORM convert_date
  USING
    iv_value TYPE any
  CHANGING
    cv_date  TYPE sy-datum
    cv_error TYPE char255.

  DATA:
    lv_raw   TYPE string,
    lv_int   TYPE string,
    lv_date8 TYPE c LENGTH 8,
    lv_month TYPE i,
    lv_day   TYPE i.

  CLEAR: cv_date, cv_error.

  lv_raw = iv_value.

  CONDENSE lv_raw NO-GAPS.

  IF lv_raw IS INITIAL.
    cv_error = 'value is blank'.
    RETURN.
  ENDIF.

* A numeric Excel cell can arrive as 20270103.0 - drop the fraction
* before the separators are removed, otherwise the trailing 0 would
* be kept as a ninth digit.
  FIND REGEX '^([0-9]+)[.,]0*$' IN lv_raw SUBMATCHES lv_int.

  IF sy-subrc = 0.
    lv_raw = lv_int.
  ENDIF.

* Accept 2027.01.03 / 2027-01-03 / 2027/01/03 as well as 20270103.
  REPLACE ALL OCCURRENCES OF REGEX '[./-]' IN lv_raw WITH ' '.

  CONDENSE lv_raw NO-GAPS.

  IF strlen( lv_raw ) <> 8.
    cv_error = |'{ lv_raw }' is not 8 digits - expected YYYYMMDD|.
    RETURN.
  ENDIF.

  lv_date8 = lv_raw.

  IF lv_date8 CN '0123456789'.
    cv_error = |'{ lv_date8 }' contains non-numeric characters|.
    RETURN.
  ENDIF.

  lv_month = lv_date8+4(2).
  lv_day   = lv_date8+6(2).

  IF lv_month < 1 OR lv_month > 12
     OR lv_day < 1 OR lv_day > 31.
    cv_error = |'{ lv_date8 }' is not a YYYYMMDD date|.
    RETURN.
  ENDIF.

  cv_date = lv_date8.

*---------------------------------------------------------------------*
* Check actual calendar date
*---------------------------------------------------------------------*
  CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
    EXPORTING
      date                      = cv_date
    EXCEPTIONS
      plausibility_check_failed = 1
      OTHERS                    = 2.

  IF sy-subrc <> 0.
    CLEAR cv_date.
    cv_error = |'{ lv_date8 }' is not an existing calendar date|.
  ENDIF.

ENDFORM.

*---------------------------------------------------------------------*
* Validate and process
*---------------------------------------------------------------------*
FORM validate_and_process.

  DATA:
    lv_dummy   TYPE tfain-ident,
    lv_jahr    TYPE tfain-jahr,
    lv_success TYPE abap_bool,
    lv_message TYPE char255,
    lv_screen  TYPE char40.

  LOOP AT gt_input INTO gs_input.

    CLEAR gs_result.

    gs_result-excel_row = gs_input-excel_row.
    gs_result-ident     = gs_input-ident.
    gs_result-date_from = gs_input-date_from.
    gs_result-date_to   = gs_input-date_to.
    gs_result-workday   = gs_input-workday.
    gs_result-wert      = gs_input-wert.

*---------------------------------------------------------------------*
* Conversion errors collected while reading the file
*---------------------------------------------------------------------*
    IF gs_input-error IS NOT INITIAL.

      gs_result-action  = 'Skipped'.
      gs_result-status  = 'ERROR'.
      gs_result-message = gs_input-error.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* Calendar ID check
*---------------------------------------------------------------------*
    IF gs_input-ident IS INITIAL.

      gs_result-action  = 'Skipped'.
      gs_result-status  = 'ERROR'.
      gs_result-message = 'Calendar ID is blank.'.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* Calendar exists in TFACD
*---------------------------------------------------------------------*
    SELECT SINGLE ident
      FROM tfacd
      INTO @lv_dummy
      WHERE ident = @gs_input-ident.

    IF sy-subrc <> 0.

      gs_result-action  = 'Skipped'.
      gs_result-status  = 'ERROR'.
      gs_result-message = 'Calendar ID does not exist in TFACD.'.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* From Date
*---------------------------------------------------------------------*
    IF gs_input-date_from IS INITIAL.

      gs_result-action  = 'Skipped'.
      gs_result-status  = 'ERROR'.
      gs_result-message =
        'From Date is invalid or blank. Expected YYYYMMDD.'.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* To Date
*---------------------------------------------------------------------*
    IF gs_input-date_to IS INITIAL.
      gs_input-date_to  = gs_input-date_from.
      gs_result-date_to = gs_input-date_to.
    ENDIF.

*---------------------------------------------------------------------*
* From <= To
*---------------------------------------------------------------------*
    IF gs_input-date_to < gs_input-date_from.

      gs_result-action  = 'Skipped'.
      gs_result-status  = 'ERROR'.
      gs_result-message = 'To Date is earlier than From Date.'.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* Same year
*---------------------------------------------------------------------*
    IF gs_input-date_from(4) <> gs_input-date_to(4).

      gs_result-action  = 'Skipped'.
      gs_result-status  = 'ERROR'.
      gs_result-message =
        'From Date and To Date must be in the same year.'.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* Existence checks
*
* The year is moved into its own variable first: an offset / length
* on a host variable is not allowed in an ABAP SQL WHERE clause.
*---------------------------------------------------------------------*
    lv_jahr = gs_input-date_from(4).

    SELECT SINGLE ident
      FROM tfain
      INTO @lv_dummy
      WHERE ident = @gs_input-ident
        AND jahr  = @lv_jahr
        AND von   = @gs_input-date_from.

    IF sy-subrc = 0.
      gs_result-tfain = 'EXISTS'.
    ELSE.
      gs_result-tfain = 'MISSING'.
    ENDIF.

    SELECT SINGLE ident
      FROM tfait
      INTO @lv_dummy
      WHERE spra  = 'E'
        AND ident = @gs_input-ident
        AND jahr  = @lv_jahr
        AND von   = @gs_input-date_from.

    IF sy-subrc = 0.
      gs_result-tfait_e = 'EXISTS'.
    ELSE.
      gs_result-tfait_e = 'MISSING'.
    ENDIF.

    SELECT SINGLE ident
      FROM tfait
      INTO @lv_dummy
      WHERE spra  = 'J'
        AND ident = @gs_input-ident
        AND jahr  = @lv_jahr
        AND von   = @gs_input-date_from.

    IF sy-subrc = 0.
      gs_result-tfait_j = 'EXISTS'.
    ELSE.
      gs_result-tfait_j = 'MISSING'.
    ENDIF.

*---------------------------------------------------------------------*
* SIMULATION
*---------------------------------------------------------------------*
    IF p_test = abap_true.

      gs_result-action = 'Simulation'.

      IF gs_result-tfain = 'EXISTS'.

        gs_result-status  = 'WARNING'.
        gs_result-message =
          'Special rule already exists. No BDC executed.'.

      ELSE.

        gs_result-status  = 'OK'.
        gs_result-message =
          'Calendar and dates valid. BDC can create new rule.'.

      ENDIF.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* Existing special rule
*
* The current recording only supports INSERT.
*---------------------------------------------------------------------*
    IF gs_result-tfain = 'EXISTS'.

      gs_result-action  = 'Skipped'.
      gs_result-status  = 'WARNING'.
      gs_result-message =
        'Special rule already exists. Change BDC recording required.'.

      APPEND gs_result TO gt_result.
      CONTINUE.

    ENDIF.

*---------------------------------------------------------------------*
* Execute SCAL BDC
*---------------------------------------------------------------------*
    CLEAR: lv_success, lv_message, lv_screen.

    PERFORM build_bdc USING gs_input.

    IF p_sess = abap_true.

      PERFORM insert_session
        CHANGING lv_success lv_message.

      IF lv_success = abap_true.
        gs_result-action  = 'In session'.
        gs_result-status  = 'SUCCESS'.
        gs_result-message = |Added to batch input session { p_group }.|.
      ELSE.
        gs_result-action = 'Session error'.
        gs_result-status = 'ERROR'.
        gs_result-message = lv_message.
      ENDIF.

    ELSE.

      PERFORM run_call_transaction
        CHANGING lv_success lv_message lv_screen.

      gs_result-screen = lv_screen.

      IF lv_success = abap_true.
        gs_result-action  = 'Created'.
        gs_result-status  = 'SUCCESS'.
        IF gs_input-workday = 'X'.
          gs_result-message =
            'Special rule created through SCAL BDC as a workday.'.
        ELSE.
          gs_result-message =
            'Special rule created through SCAL BDC as non-working.'.
        ENDIF.
      ELSE.
        gs_result-action = 'BDC Error'.
        gs_result-status = 'ERROR'.
        gs_result-message = lv_message.
      ENDIF.

    ENDIF.

    APPEND gs_result TO gt_result.

  ENDLOOP.

ENDFORM.

*---------------------------------------------------------------------*
* Build the SCAL BDC for one row
*
* Follows the SHDB recording of 2026 01 06 - 2026 01 08 on calendar A1
* screen for screen and OK code for OK code.
*
* The only field values not sent unconditionally are the screen 0200
* header fields - see FORM BDC_FIELDS_0200 and P_REC200.
*---------------------------------------------------------------------*
FORM build_bdc
  USING
    is_input TYPE ty_input.

  DATA:
    lv_from_ext TYPE char20,
    lv_to_ext   TYPE char20.

  CLEAR: gt_bdcdata, gt_bdcmsg.

*---------------------------------------------------------------------*
* Dates have to reach the screen in the date format of the user who
* runs the BDC, not in the internal YYYYMMDD representation. The
* recording shows 2026.01.06, i.e. the recording user had date format
* 4 (YYYY.MM.DD) - which is exactly why this is converted per user
* instead of being formatted with a fixed pattern.
*---------------------------------------------------------------------*
  PERFORM convert_date_external
    USING    is_input-date_from
    CHANGING lv_from_ext.

  PERFORM convert_date_external
    USING    is_input-date_to
    CHANGING lv_to_ext.

*---------------------------------------------------------------------*
* SCAL - initial screen, maintain factory calendar
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SAPMSFT0' '0100'.
  PERFORM bdc_field  USING 'BDC_CURSOR'    'FMEN-FABKAL'.
  PERFORM bdc_field  USING 'BDC_OKCODE'    '=UPD'.
  PERFORM bdc_field  USING 'FMEN-FEIERTAG' space.
  PERFORM bdc_field  USING 'FMEN-FABKAL'   'X'.

*---------------------------------------------------------------------*
* Calendar list - recording lines 7 to 12
*
* Both 0120 screens are sent as recorded, the =&IC1 double click
* included. There is no SAPLSKBH 0830 filter-field popup in this
* recording, so none is built.
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SAPMSSY0' '0120'.
  PERFORM bdc_field  USING 'BDC_CURSOR' gc_cur_unfiltered.
  PERFORM bdc_field  USING 'BDC_OKCODE' '=&IC1'.

  PERFORM bdc_dynpro USING 'SAPMSSY0' '0120'.
  PERFORM bdc_field  USING 'BDC_CURSOR' gc_cur_unfiltered.
  PERFORM bdc_field  USING 'BDC_OKCODE' '=&ILT'.

*---------------------------------------------------------------------*
* Filter value = calendar ID
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SAPLSSEL' '1104'.
  PERFORM bdc_field  USING 'BDC_OKCODE' '=CRET'.
  PERFORM bdc_field  USING 'BDC_SUBSCR'
    'SAPLSSEL                                1105%_SUBSCREEN_FREESEL'.
  PERFORM bdc_field  USING 'BDC_CURSOR'   '%%DYN001-LOW'.
  PERFORM bdc_field  USING '%%DYN001-LOW' is_input-ident.

*---------------------------------------------------------------------*
* Filtered list - open the calendar in change mode
*
* The cursor decides WHICH line =UPDA opens, so this position is what
* makes the filter necessary: with exactly one calendar left, the data
* line sits at 04/03. If the list layout differs in your system, adjust
* GC_CUR_FILTERED - a wrong position opens the wrong calendar.
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SAPMSSY0' '0120'.
  PERFORM bdc_field  USING 'BDC_CURSOR' gc_cur_filtered.
  PERFORM bdc_field  USING 'BDC_OKCODE' '=UPDA'.

*---------------------------------------------------------------------*
* Calendar definition -> special rules - recording lines 21 to 36
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SZC_FACTORY_CALENDAR_MAINTAIN' '0200'.
  PERFORM bdc_field  USING 'BDC_CURSOR' 'TFACT-LTEXT'.
  PERFORM bdc_field  USING 'BDC_OKCODE' '=SRUL'.
  PERFORM bdc_fields_0200.

*---------------------------------------------------------------------*
* Special rules - insert
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SZC_FACTORY_CALENDAR_MAINTAIN' '0210'.
  PERFORM bdc_field  USING 'BDC_CURSOR' 'TIFAB-DATUMVON(01)'.
  PERFORM bdc_field  USING 'BDC_OKCODE' '=INS'.

*---------------------------------------------------------------------*
* Insert special rule - recording lines 40 to 46
*
* TIFAB-ARBTAG is the workday indicator, and it IS on this screen - the
* first recording simply did not contain it, because that rule was
* recorded as non-working and SHDB does not write out an untouched
* checkbox. Column D of the template goes here.
*
* It is sent on every row, blank included, rather than only when the
* column is ticked: an explicit blank states "non-working" instead of
* relying on whatever the freshly opened screen happens to default to.
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SZC_FACTORY_CALENDAR_MAINTAIN' '0215'.
  PERFORM bdc_field  USING 'BDC_CURSOR'     'TIFAB-DATUMBIS'.
  PERFORM bdc_field  USING 'BDC_OKCODE'     '=RINS'.
  PERFORM bdc_field  USING 'TIFAB-DATUMVON' lv_from_ext.
  PERFORM bdc_field  USING 'TIFAB-DATUMBIS' lv_to_ext.
  PERFORM bdc_field  USING 'TIFAB-ARBTAG'   is_input-workday.
  PERFORM bdc_field  USING 'TFAIT-LTEXT'    is_input-text.

*---------------------------------------------------------------------*
* Special rules - save
*---------------------------------------------------------------------*
  PERFORM bdc_dynpro USING 'SZC_FACTORY_CALENDAR_MAINTAIN' '0210'.
  PERFORM bdc_field  USING 'BDC_CURSOR' 'TIFAB-DATUMVON(01)'.
  PERFORM bdc_field  USING 'BDC_OKCODE' '=SAVE'.

  PERFORM build_bdc_tail.

ENDFORM.

*---------------------------------------------------------------------*
* Header fields the recording captured on screen 0200
*
*   TFACT-LTEXT 016026LT1   TFACD-VJAHR 2000   TFACD-BJAHR 2099
*   TFACD-HOCID JP          TFACD-BASIS 989
*   TIFAB-MONTAG..FREITAG X   SAMSTAG / SONNTAG / FEIERTAG blank
*
* SHDB records every input-ready field on a screen, not only the ones
* that were typed, so these are the DEFINITION OF CALENDAR A1 at
* recording time - validity 2000-2099, holiday calendar JP, basis 989,
* Monday to Friday working.
*
* Sent only when P_REC200 is ticked, because sending them writes A1's
* definition into whichever calendar the row is for. On A1 itself that
* is harmless; on any other calendar it silently replaces the validity
* period, the holiday calendar, the basis and the working week. Leaving
* them out cannot break the run - an unsupplied field keeps the value
* the screen already holds, and the screen sequence is unaffected.
*
* The recording writes the three non-working checkboxes as '_'. That is
* how SHDB shows an unticked checkbox; a literal underscore is not
* blank, and on a checkbox any non-blank value counts as ticked, which
* would turn Saturday, Sunday and holidays into working days. They are
* therefore sent as SPACE.
*---------------------------------------------------------------------*
FORM bdc_fields_0200.

  CHECK p_rec200 = abap_true.

  PERFORM bdc_field USING 'TFACT-LTEXT'      '016026LT1'.
  PERFORM bdc_field USING 'TFACD-VJAHR'      '2000'.
  PERFORM bdc_field USING 'TFACD-BJAHR'      '2099'.
  PERFORM bdc_field USING 'TFACD-HOCID'      'JP'.
  PERFORM bdc_field USING 'TFACD-BASIS'      '989'.
  PERFORM bdc_field USING 'TIFAB-MONTAG'     'X'.
  PERFORM bdc_field USING 'TIFAB-DIENSTAG'   'X'.
  PERFORM bdc_field USING 'TIFAB-MITTWOCH'   'X'.
  PERFORM bdc_field USING 'TIFAB-DONNERSTAG' 'X'.
  PERFORM bdc_field USING 'TIFAB-FREITAG'    'X'.
  PERFORM bdc_field USING 'TIFAB-SAMSTAG'    space.
  PERFORM bdc_field USING 'TIFAB-SONNTAG'    space.
  PERFORM bdc_field USING 'TIFAB-FEIERTAG'   space.

ENDFORM.

*---------------------------------------------------------------------*
* Everything that still happens after =SAVE
*
* Batch input does not stop when the data is saved - it stops when the
* TRANSACTION ends. Every screen SCAL still shows after the save needs
* its own entry here, otherwise the run dies with SY-SUBRC = 1001 ("no
* batch input data for screen ...") in the background and simply halts
* on that screen in the foreground.
*---------------------------------------------------------------------*
FORM build_bdc_tail.

*---------------------------------------------------------------------*
* Information popup raised by the save
*
*   "Transporting the holiday and factory calendar
*    The automatic recording of customizing changes does not include
*    the holiday and factory calendar. ..."
*
* It is a list shown in a dialog box, which is why it appears in the
* recording as SAPMSSY0 0120 rather than as a popup program, and why it
* carries the print and find buttons. =DBAC is its green check.
*
* Defaults come from the recording; they stay on the selection screen
* so a system that raises a different popup can be corrected without a
* program change - the "Stopped on" column names what to enter.
*---------------------------------------------------------------------*
  IF p_pprog IS NOT INITIAL
     AND p_pdynp IS NOT INITIAL.

    PERFORM bdc_dynpro USING p_pprog p_pdynp.
    PERFORM bdc_field  USING 'BDC_OKCODE' p_pokcd.

  ENDIF.

*---------------------------------------------------------------------*
* Leave the transaction
*
*   0210 -> 0200 -> calendar list -> SCAL initial screen -> out
*
* The header fields the recording captured on 0200 are left out here
* for the same reason as in BUILD_BDC.
*---------------------------------------------------------------------*
  IF p_exit = abap_true.

    PERFORM bdc_dynpro USING 'SZC_FACTORY_CALENDAR_MAINTAIN' '0210'.
    PERFORM bdc_field  USING 'BDC_CURSOR' 'TIFAB-DATUMVON(01)'.
    PERFORM bdc_field  USING 'BDC_OKCODE' '=BACK'.

    PERFORM bdc_dynpro USING 'SZC_FACTORY_CALENDAR_MAINTAIN' '0200'.
    PERFORM bdc_field  USING 'BDC_CURSOR' 'TFACT-LTEXT'.
    PERFORM bdc_field  USING 'BDC_OKCODE' '=BACK'.
    PERFORM bdc_fields_0200.

    PERFORM bdc_dynpro USING 'SAPMSSY0' '0120'.
    PERFORM bdc_field  USING 'BDC_CURSOR' gc_cur_filtered.
    PERFORM bdc_field  USING 'BDC_OKCODE' '=&F03'.

    PERFORM bdc_dynpro USING 'SAPMSFT0' '0100'.
    PERFORM bdc_field  USING 'BDC_CURSOR'  'TEXT_01_CALENDAR'.
    PERFORM bdc_field  USING 'BDC_OKCODE'  '=BACK'.
    PERFORM bdc_field  USING 'FMEN-FABKAL' 'X'.

  ENDIF.

ENDFORM.


*---------------------------------------------------------------------*
* Run the BDC with CALL TRANSACTION
*---------------------------------------------------------------------*
FORM run_call_transaction
  CHANGING
    cv_success TYPE abap_bool
    cv_message TYPE char255
    cv_screen  TYPE char40.

  DATA:
    ls_opt   TYPE ctu_params,
    lv_subrc TYPE sy-subrc,
    lv_error TYPE char255,
    lv_all   TYPE char255.

  CLEAR: cv_success, cv_message, cv_screen.

  ls_opt-dismode = p_mode.
  ls_opt-updmode = p_updt.
  ls_opt-defsize = abap_false.

  CALL TRANSACTION gc_tcode
    WITH AUTHORITY-CHECK
    USING gt_bdcdata
    OPTIONS FROM ls_opt
    MESSAGES INTO gt_bdcmsg.

  lv_subrc = sy-subrc.

  PERFORM collect_bdc_messages
    CHANGING lv_error lv_all cv_screen.

* SY-SUBRC on its own is not a reliable success indicator for a BDC:
* an error message collected during the transaction means the rule was
* not saved even when the transaction itself ended cleanly.
  IF lv_subrc = 0 AND lv_error IS INITIAL.
    cv_success = abap_true.
    RETURN.
  ENDIF.

  cv_success = abap_false.

*---------------------------------------------------------------------*
* SY-SUBRC = 1001 means the transaction was still running when the BDC
* data ran out. On its own that number says nothing, so the screen the
* run stopped on and every collected message are reported with it.
*---------------------------------------------------------------------*
  IF cv_screen IS NOT INITIAL.

    cv_message =
      |BDC data ends while screen { cv_screen } is still active | &&
      |(SY-SUBRC = { lv_subrc }). Add this screen to FORM | &&
      |BUILD_BDC_TAIL.|.

  ELSEIF lv_error IS NOT INITIAL.

    cv_message = lv_error.

  ELSEIF lv_all IS NOT INITIAL.

    cv_message = |SY-SUBRC = { lv_subrc }: { lv_all }|.

  ELSE.

    cv_message =
      |CALL TRANSACTION { gc_tcode } failed. SY-SUBRC = { lv_subrc }. | &&
      |No message was returned - run again with P_MODE = 'A'.|.

  ENDIF.

ENDFORM.

*---------------------------------------------------------------------*
* Open the batch input session
*---------------------------------------------------------------------*
FORM open_session.

  DATA:
    lv_text TYPE char255.

  IF p_sess <> abap_true
     OR p_test = abap_true.
    RETURN.
  ENDIF.

  CALL FUNCTION 'BDC_OPEN_GROUP'
    EXPORTING
      client              = sy-mandt
      group               = p_group
      user                = sy-uname
      keep                = 'X'
    EXCEPTIONS
      client_invalid      = 1
      destination_invalid = 2
      group_invalid       = 3
      group_is_locked     = 4
      holddate_invalid    = 5
      internal_error      = 6
      queue_error         = 7
      running             = 8
      system_lock_error   = 9
      user_invalid        = 10
      OTHERS              = 11.

  IF sy-subrc = 0.
    gv_session = abap_true.
  ELSE.
    CLEAR gv_session.
    lv_text = |Batch input session { p_group } could not be opened.|.
    MESSAGE lv_text TYPE 'S' DISPLAY LIKE 'E'.
  ENDIF.

ENDFORM.

*---------------------------------------------------------------------*
* Insert one transaction into the batch input session
*---------------------------------------------------------------------*
FORM insert_session
  CHANGING
    cv_success TYPE abap_bool
    cv_message TYPE char255.

  CLEAR: cv_success, cv_message.

  IF gv_session <> abap_true.
    cv_message = 'Batch input session is not open.'.
    RETURN.
  ENDIF.

  CALL FUNCTION 'BDC_INSERT'
    EXPORTING
      tcode            = gc_tcode
    TABLES
      dynprotab        = gt_bdcdata
    EXCEPTIONS
      internal_error   = 1
      not_open         = 2
      queue_error      = 3
      tcode_invalid    = 4
      printing_invalid = 5
      posting_invalid  = 6
      OTHERS           = 7.

  IF sy-subrc = 0.
    cv_success = abap_true.
  ELSE.
    cv_message = |BDC_INSERT failed. SY-SUBRC = { sy-subrc }|.
  ENDIF.

ENDFORM.

*---------------------------------------------------------------------*
* Close the batch input session
*---------------------------------------------------------------------*
FORM close_session.

  DATA:
    lv_text TYPE char255.

  IF gv_session <> abap_true.
    RETURN.
  ENDIF.

  CALL FUNCTION 'BDC_CLOSE_GROUP'
    EXCEPTIONS
      not_open    = 1
      queue_error = 2
      OTHERS      = 3.

  CLEAR gv_session.

  IF sy-subrc = 0.
    lv_text =
      |Batch input session { p_group } created. Process it in SM35.|.
    MESSAGE lv_text TYPE 'S'.
  ENDIF.

ENDFORM.

*---------------------------------------------------------------------*
* Add BDC screen
*---------------------------------------------------------------------*
FORM bdc_dynpro
  USING
    iv_program TYPE any
    iv_dynpro  TYPE any.

  CLEAR gs_bdcdata.

  gs_bdcdata-program  = iv_program.
  gs_bdcdata-dynpro   = iv_dynpro.
  gs_bdcdata-dynbegin = 'X'.

  APPEND gs_bdcdata TO gt_bdcdata.

ENDFORM.

*---------------------------------------------------------------------*
* Add BDC field
*---------------------------------------------------------------------*
FORM bdc_field
  USING
    iv_fnam TYPE any
    iv_fval TYPE any.

  CLEAR gs_bdcdata.

  gs_bdcdata-fnam = iv_fnam.
  gs_bdcdata-fval = iv_fval.

  APPEND gs_bdcdata TO gt_bdcdata.

ENDFORM.

*---------------------------------------------------------------------*
* Convert internal date to the date format of the current user
*---------------------------------------------------------------------*
FORM convert_date_external
  USING
    iv_date TYPE sy-datum
  CHANGING
    cv_date TYPE char20.

  DATA:
    lv_datfm TYPE usr01-datfm.

  CLEAR cv_date.

  IF iv_date IS INITIAL.
    RETURN.
  ENDIF.

  CALL FUNCTION 'CONVERT_DATE_TO_EXTERNAL'
    EXPORTING
      date_internal            = iv_date
    IMPORTING
      date_external            = cv_date
    EXCEPTIONS
      date_internal_is_invalid = 1
      OTHERS                   = 2.

  IF sy-subrc = 0.
    RETURN.
  ENDIF.

*---------------------------------------------------------------------*
* Fallback: build the string from the user's own date format instead
* of assuming YYYY.MM.DD - a BDC field in the wrong format is rejected
* by the screen.
*---------------------------------------------------------------------*
  CLEAR cv_date.

  SELECT SINGLE datfm
    FROM usr01
    INTO @lv_datfm
    WHERE bname = @sy-uname.

  CASE lv_datfm.
    WHEN '1'.                                     " DD.MM.YYYY
      cv_date = |{ iv_date+6(2) }.{ iv_date+4(2) }.{ iv_date(4) }|.
    WHEN '2'.                                     " MM/DD/YYYY
      cv_date = |{ iv_date+4(2) }/{ iv_date+6(2) }/{ iv_date(4) }|.
    WHEN '3'.                                     " MM-DD-YYYY
      cv_date = |{ iv_date+4(2) }-{ iv_date+6(2) }-{ iv_date(4) }|.
    WHEN '4'.                                     " YYYY.MM.DD
      cv_date = |{ iv_date(4) }.{ iv_date+4(2) }.{ iv_date+6(2) }|.
    WHEN '5'.                                     " YYYY/MM/DD
      cv_date = |{ iv_date(4) }/{ iv_date+4(2) }/{ iv_date+6(2) }|.
    WHEN '6'.                                     " YYYY-MM-DD
      cv_date = |{ iv_date(4) }-{ iv_date+4(2) }-{ iv_date+6(2) }|.
    WHEN OTHERS.
      cv_date = iv_date.
  ENDCASE.

ENDFORM.

*---------------------------------------------------------------------*
* Collect the messages of the last CALL TRANSACTION
*
*   CV_ERROR  - only E / A / X, the messages that mean "not saved"
*   CV_ALL    - every message, so a failure without an error message
*               can still be diagnosed
*   CV_SCREEN - program and dynpro the run stopped on, taken from
*               message 00 344 "No batch input data for screen &1 &2"
*
* The original version collected E / A / X only. Message 00 344 is
* raised as a status message, so a run that died with SY-SUBRC = 1001
* produced an empty message and the bare return code.
*---------------------------------------------------------------------*
FORM collect_bdc_messages
  CHANGING
    cv_error  TYPE char255
    cv_all    TYPE char255
    cv_screen TYPE char40.

  DATA:
    lv_text TYPE char255.

  CLEAR: cv_error, cv_all, cv_screen.

  LOOP AT gt_bdcmsg INTO gs_bdcmsg.

*---------------------------------------------------------------------*
* "No batch input data for screen &1 &2" - the missing screen
*---------------------------------------------------------------------*
    IF gs_bdcmsg-msgid = '00'
       AND gs_bdcmsg-msgnr = '344'.
      cv_screen = |{ gs_bdcmsg-msgv1 } { gs_bdcmsg-msgv2 }|.
      CONDENSE cv_screen.
    ENDIF.

    CLEAR lv_text.

    CALL FUNCTION 'MESSAGE_TEXT_BUILD'
      EXPORTING
        msgid               = gs_bdcmsg-msgid
        msgnr               = gs_bdcmsg-msgnr
        msgv1               = gs_bdcmsg-msgv1
        msgv2               = gs_bdcmsg-msgv2
        msgv3               = gs_bdcmsg-msgv3
        msgv4               = gs_bdcmsg-msgv4
      IMPORTING
        message_text_output = lv_text
      EXCEPTIONS
        OTHERS              = 1.

    IF sy-subrc <> 0
       OR lv_text IS INITIAL.
      lv_text = |{ gs_bdcmsg-msgid }{ gs_bdcmsg-msgnr }|.
    ENDIF.

    lv_text = |{ gs_bdcmsg-msgtyp }: { lv_text }|.

    IF cv_all IS INITIAL.
      cv_all = lv_text.
    ELSE.
      cv_all = |{ cv_all } \| { lv_text }|.
    ENDIF.

    CHECK gs_bdcmsg-msgtyp = 'E'
       OR gs_bdcmsg-msgtyp = 'A'
       OR gs_bdcmsg-msgtyp = 'X'.

    IF cv_error IS INITIAL.
      cv_error = lv_text.
    ELSE.
      cv_error = |{ cv_error } \| { lv_text }|.
    ENDIF.

  ENDLOOP.

ENDFORM.

*---------------------------------------------------------------------*
* Display ALV
*---------------------------------------------------------------------*
FORM display_alv.

  DATA:
    lo_alv TYPE REF TO cl_salv_table.

  IF gt_result IS INITIAL.
    MESSAGE 'No result to display.' TYPE 'S'.
    RETURN.
  ENDIF.

  TRY.

      cl_salv_table=>factory(
        IMPORTING
          r_salv_table = lo_alv
        CHANGING
          t_table      = gt_result ).

      lo_alv->get_functions( )->set_all( abap_true ).
      lo_alv->get_columns( )->set_optimize( abap_true ).
      lo_alv->get_display_settings( )->set_striped_pattern( abap_true ).
      lo_alv->get_display_settings( )->set_list_header(
        'Factory Calendar Special Rule Upload Result' ).

      lo_alv->display( ).

    CATCH cx_salv_msg INTO DATA(lx_salv).

      MESSAGE lx_salv->get_text( )
        TYPE 'S' DISPLAY LIKE 'E'.

  ENDTRY.

ENDFORM.
