/// Order API for the 2019 web project: JSON over the legacy ^SORD routines.
/// Dates in and out are ISO (YYYY-MM-DD).
Class OM.API.Order [ Abstract ]
{

/// The order with its lines as a JSON object, or "" when there is no such order.
ClassMethod Get(id As %Integer) As %DynamicObject
{
    set rec = $get(^SORD(+id))
    quit:rec="" ""
    set obj = ..Summary(+id)
    set obj.invoice = $piece(rec, "^", 5)
    set obj.lines = []
    set ln = ""
    for {
        set ln = $order(^SORD(+id, "L", ln), 1, line)
        quit:ln=""
        do obj.lines.%Push({
            "line": (+ln),
            "sku": ($piece(line, "^", 1)),
            "qty": (+$piece(line, "^", 2)),
            "price": (+$piece(line, "^", 3)),
            "total": (+$piece(line, "^", 4))
        })
    }
    quit obj
}

/// Orders dated from through to, through BYDATE^OMORDL.
ClassMethod ListByDate(from As %String, to As %String) As %DynamicArray [ PublicList = (FROM, TO) ]
{
    new FROM, TO
    set FROM = $zdateh(from, 3), TO = $zdateh(to, 3)
    do BYDATE^OMORDL
    quit ..Collect()
}

/// Orders of a customer, newest first, through BYCUST^OMORDL.
ClassMethod ListByCustomer(customerId As %Integer) As %DynamicArray [ PublicList = CID ]
{
    new CID
    set CID = +customerId
    do BYCUST^OMORDL
    quit ..Collect()
}

/// Open a new order for a customer through NEW^OMORD and return its number.
ClassMethod Create(customerId As %Integer) As %Integer [ PublicList = (CID, ORD, ERR) ]
{
    new CID, ORD, ERR
    set CID = +customerId
    do NEW^OMORD
    do ..Check()
    quit ORD
}

/// Add a line to an open order through ADDL^OMORD.
ClassMethod AddLine(orderId As %Integer, sku As %String, qty As %Integer) [ PublicList = (ORD, SKU, QTY, ERR) ]
{
    new ORD, SKU, QTY, ERR
    set ORD = +orderId, SKU = sku, QTY = qty
    do ADDL^OMORD
    do ..Check()
}

/// Ship an open order through SHIP^OMORD.
ClassMethod Ship(orderId As %Integer) [ PublicList = (ORD, ERR) ]
{
    new ORD, ERR
    set ORD = +orderId
    do SHIP^OMORD
    do ..Check()
}

/// Cancel an open order through CANCEL^OMORD.
ClassMethod Cancel(orderId As %Integer) [ PublicList = (ORD, ERR) ]
{
    new ORD, ERR
    set ORD = +orderId
    do CANCEL^OMORD
    do ..Check()
}

/// Turn the legacy ERR variable into an exception.
ClassMethod Check() [ Private, PublicList = ERR ]
{
    if $data(ERR) {
        throw ##class(%Exception.General).%New("OMS", 5001, , ERR)
    }
}

ClassMethod Collect() As %DynamicArray [ Private ]
{
    set out = []
    set i = ""
    for {
        set i = $order(^TMP($job, "OL", i), 1, ord)
        quit:i=""
        do out.%Push(..Summary(ord))
    }
    kill ^TMP($job, "OL")
    quit out
}

ClassMethod Summary(ord As %Integer) As %DynamicObject [ Private ]
{
    set rec = ^SORD(ord)
    quit {
        "id": (+ord),
        "customer": (+$piece(rec, "^", 1)),
        "date": ($zdate($piece(rec, "^", 2), 3)),
        "status": ($piece(rec, "^", 3)),
        "total": (+$piece(rec, "^", 4))
    }
}

}
