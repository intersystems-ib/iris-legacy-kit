/// Invoice API for the web UI: JSON over the ^INVC globals kept by OMINV and OMPAY.
/// Dates out are ISO (YYYY-MM-DD).
Class OM.API.Invoice [ Abstract ]
{

/// The invoice as a JSON object, or "" when there is no such invoice.
ClassMethod Get(id As %Integer) As %DynamicObject
{
    set rec = $get(^INVC(+id))
    quit:rec="" ""
    quit {
        "id": (+id),
        "order": (+$piece(rec, "^", 1)),
        "customer": (+$piece(rec, "^", 2)),
        "date": ($zdate($piece(rec, "^", 3), 3)),
        "amount": (+$piece(rec, "^", 4)),
        "due": ($zdate($piece(rec, "^", 5), 3)),
        "paid": (+$piece(rec, "^", 6)),
        "outstanding": ($piece(rec, "^", 4) - $piece(rec, "^", 6)),
        "status": ($piece(rec, "^", 7))
    }
}

/// Invoices of a customer, newest first, from the ^INVCX("C") index.
ClassMethod ListByCustomer(customerId As %Integer) As %DynamicArray
{
    set out = []
    set inv = ""
    for {
        set inv = $order(^INVCX("C", +customerId, inv), -1)
        quit:inv=""
        set obj = ..Get(inv)
        do:obj'="" out.%Push(obj)
    }
    quit out
}

}
