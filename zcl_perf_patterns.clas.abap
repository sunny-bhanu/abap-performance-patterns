"! <p class="shorttext synchronized">ABAP performance patterns - before / after</p>
"! Each pair of methods shows the slow version (_slow) and the version
"! that replaced it in production (_fast). Types are deliberately simple
"! so the shape of the pattern is visible, not the business case.
CLASS zcl_perf_patterns DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    TYPES: BEGIN OF ty_header,
             docno TYPE char10,
             date  TYPE d,
           END OF ty_header,
           tt_header TYPE STANDARD TABLE OF ty_header WITH EMPTY KEY,

           BEGIN OF ty_item,
             docno TYPE char10,
             item  TYPE numc6,
             qty   TYPE p LENGTH 13 DECIMALS 3,
           END OF ty_item,
           tt_item   TYPE STANDARD TABLE OF ty_item WITH EMPTY KEY,

           BEGIN OF ty_total,
             docno TYPE char10,
             date  TYPE d,
             qty   TYPE p LENGTH 13 DECIMALS 3,
           END OF ty_total,
           tt_total  TYPE STANDARD TABLE OF ty_total WITH EMPTY KEY.

    "! Pattern 1 - nested SELECT in a loop vs FOR ALL ENTRIES (guarded)
    METHODS items_for_headers_slow
      IMPORTING it_header TYPE tt_header
      RETURNING VALUE(rt_item) TYPE tt_item.
    METHODS items_for_headers_fast
      IMPORTING it_header TYPE tt_header
      RETURNING VALUE(rt_item) TYPE tt_item.

    "! Pattern 2 - nested LOOP vs parallel cursor
    METHODS totals_slow
      IMPORTING it_header TYPE tt_header it_item TYPE tt_item
      RETURNING VALUE(rt_total) TYPE tt_total.
    METHODS totals_fast
      IMPORTING it_header TYPE tt_header it_item TYPE tt_item
      RETURNING VALUE(rt_total) TYPE tt_total.

    "! Pattern 3 - READ TABLE on standard table vs hashed table lookup
    METHODS lookup_slow
      IMPORTING it_header TYPE tt_header it_item TYPE tt_item
      RETURNING VALUE(rt_total) TYPE tt_total.
    METHODS lookup_fast
      IMPORTING it_header TYPE tt_header it_item TYPE tt_item
      RETURNING VALUE(rt_total) TYPE tt_total.
ENDCLASS.



CLASS zcl_perf_patterns IMPLEMENTATION.

*--------------------------------------------------------------------*
* Pattern 1: database round trips
*--------------------------------------------------------------------*
  METHOD items_for_headers_slow.
    " One database round trip PER header row. 10,000 headers =
    " 10,000 SELECTs. Classic N+1.
    LOOP AT it_header INTO DATA(ls_header).
      SELECT docno, item, qty
        FROM zperf_item
        WHERE docno = @ls_header-docno
        APPENDING TABLE @rt_item.
    ENDLOOP.
  ENDMETHOD.


  METHOD items_for_headers_fast.
    " Guard 1: an EMPTY driver table makes FOR ALL ENTRIES select
    "          the WHOLE table. Always check first.
    IF it_header IS INITIAL.
      RETURN.
    ENDIF.

    " Guard 2: de-duplicate the driver table - the kernel splits it
    "          into blocks and duplicates inflate the number of blocks.
    DATA(lt_keys) = it_header.
    SORT lt_keys BY docno.
    DELETE ADJACENT DUPLICATES FROM lt_keys COMPARING docno.

    " Guard 3: select only the fields you need, into a typed table -
    "          FOR ALL ENTRIES implicitly removes duplicate ROWS from the
    "          result, so the field list must include the full key.
    SELECT docno, item, qty
      FROM zperf_item
      FOR ALL ENTRIES IN @lt_keys
      WHERE docno = @lt_keys-docno
      INTO TABLE @rt_item.
  ENDMETHOD.


*--------------------------------------------------------------------*
* Pattern 2: nested loops  ->  parallel cursor
*--------------------------------------------------------------------*
  METHOD totals_slow.
    " O(n*m): every header scans every item.
    LOOP AT it_header INTO DATA(ls_header).
      DATA(ls_total) = VALUE ty_total( docno = ls_header-docno
                                       date  = ls_header-date ).
      LOOP AT it_item INTO DATA(ls_item) WHERE docno = ls_header-docno.
        ls_total-qty += ls_item-qty.
      ENDLOOP.
      APPEND ls_total TO rt_total.
    ENDLOOP.
  ENDMETHOD.


  METHOD totals_fast.
    " O(n+m): both tables sorted by the join key, inner loop starts at
    " the remembered index and leaves as soon as the key changes.
    DATA(lt_header) = it_header.
    DATA(lt_item)   = it_item.
    SORT lt_header BY docno.
    SORT lt_item   BY docno.

    DATA lv_idx TYPE sy-tabix VALUE 1.

    LOOP AT lt_header INTO DATA(ls_header).
      DATA(ls_total) = VALUE ty_total( docno = ls_header-docno
                                       date  = ls_header-date ).

      " Position the item cursor on the first item of this header
      READ TABLE lt_item TRANSPORTING NO FIELDS
           WITH KEY docno = ls_header-docno
           BINARY SEARCH.
      IF sy-subrc = 0.
        lv_idx = sy-tabix.
        LOOP AT lt_item INTO DATA(ls_item) FROM lv_idx.
          IF ls_item-docno <> ls_header-docno.
            EXIT.                       " key changed - stop scanning
          ENDIF.
          ls_total-qty += ls_item-qty.
        ENDLOOP.
      ENDIF.

      APPEND ls_total TO rt_total.
    ENDLOOP.
  ENDMETHOD.


*--------------------------------------------------------------------*
* Pattern 3: lookups  ->  hashed table
*--------------------------------------------------------------------*
  METHOD lookup_slow.
    " READ TABLE ... WITH KEY on an unsorted standard table is a linear
    " scan: O(n) per lookup, O(n*m) overall.
    LOOP AT it_item INTO DATA(ls_item).
      READ TABLE it_header INTO DATA(ls_header)
           WITH KEY docno = ls_item-docno.
      IF sy-subrc = 0.
        APPEND VALUE #( docno = ls_item-docno
                        date  = ls_header-date
                        qty   = ls_item-qty ) TO rt_total.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD lookup_fast.
    " Build a hashed copy once: O(1) per lookup afterwards.
    " Use this when the lookup table is read many times and the key is
    " unique. For non-unique keys use a SORTED table + BINARY SEARCH.
    DATA lt_header_h TYPE HASHED TABLE OF ty_header WITH UNIQUE KEY docno.
    lt_header_h = it_header.          " duplicates would raise an exception

    LOOP AT it_item INTO DATA(ls_item).
      READ TABLE lt_header_h INTO DATA(ls_header)
           WITH TABLE KEY docno = ls_item-docno.
      IF sy-subrc = 0.
        APPEND VALUE #( docno = ls_item-docno
                        date  = ls_header-date
                        qty   = ls_item-qty ) TO rt_total.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.
