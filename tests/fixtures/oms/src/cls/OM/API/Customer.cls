/// Customer API for the 2019 web project: JSON over the legacy ^CUST routines.
/// The routines take their parameters from the symbol table, so methods that call them
/// declare those variables in their PublicList.
Class OM.API.Customer [ Abstract ]
{

/// The customer as a JSON object, or "" when there is no such customer.
ClassMethod Get(id As %Integer) As %DynamicObject
{
    set rec = $get(^CUST(+id))
    quit:rec="" ""
    set obj = {
        "id": (+id),
        "name": ($piece(rec, "^", 1)),
        "country": ($piece(rec, "^", 2)),
        "since": ($zdate($piece(rec, "^", 3), 3)),
        "status": ($piece(rec, "^", 4)),
        "creditLimit": (+$piece(rec, "^", 5)),
        "phone": ($piece(rec, "^", 6)),
        "address": []
    }
    set n = ""
    for {
        set n = $order(^CUST(+id, "A", n), 1, line)
        quit:n=""
        do obj.address.%Push(line)
    }
    quit obj
}

/// The first max customers by id, for browsing in the web UI.
ClassMethod List(max As %Integer = 50) As %DynamicArray
{
    set out = []
    set id = ""
    for {
        set id = $order(^CUST(id), 1, rec)
        quit:(id="")||(out.%Size()>=max)
        do out.%Push({"id": (+id), "name": ($piece(rec, "^", 1)), "country": ($piece(rec, "^", 2))})
    }
    quit out
}

/// Customers whose name starts with prefix, through FIND^OMCUSTL.
ClassMethod Find(prefix As %String) As %DynamicArray [ PublicList = X ]
{
    new X
    set X = prefix
    do FIND^OMCUSTL
    set out = []
    set i = ""
    for {
        set i = $order(^TMP($job, "CL", i), 1, row)
        quit:i=""
        do out.%Push({"id": (+$piece(row, "^", 1)), "name": ($piece(row, "^", 2)), "country": ($piece(row, "^", 3))})
    }
    kill ^TMP($job, "CL")
    quit out
}

/// Create a customer through ADD^OMCUST and return its id.
ClassMethod Create(name As %String, country As %String, creditLimit As %Integer, phone As %String = "") As %Integer [ PublicList = (CNAME, CCTRY, CLIM, CPHONE, CADDR, CID, ERR) ]
{
    new CNAME, CCTRY, CLIM, CPHONE, CADDR, CID, ERR
    set CNAME = $zconvert(name, "U"), CCTRY = $zconvert(country, "U"), CLIM = creditLimit, CPHONE = phone
    do ADD^OMCUST
    if $data(ERR) {
        throw ##class(%Exception.General).%New("OMS", 5001, , ERR)
    }
    quit CID
}

/// Delete a customer through DEL^OMCUST.
ClassMethod Delete(id As %Integer) [ PublicList = (CID, ERR) ]
{
    new CID, ERR
    set CID = +id
    do DEL^OMCUST
    if $data(ERR) {
        throw ##class(%Exception.General).%New("OMS", 5001, , ERR)
    }
}

}
