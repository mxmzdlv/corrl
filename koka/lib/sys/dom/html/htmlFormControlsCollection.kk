public module sys/dom/html/htmlFormControlsCollection

// Interface HTMLFormControlsCollection (generated by esidl 0.2.0).

import sys/dom/types

/* safe and unsafe conversion from all types including `any */
external inline maybeHtmlFormControlsCollection  : forall<a> (a) -> maybe<htmlFormControlsCollection>
{ inline "(#1.toString()==='[object HTMLFormControlsCollection]'?std_core.Just(#1):std_core.Nothing)" }
external inline toHtmlFormControlsCollection : forall<a> (a) -> exn htmlFormControlsCollection
{ inline "(#1.toString()==='[object HTMLFormControlsCollection]'?#1:std_core.error('toHtmlFormControlsCollection: cast failed'))" }


// HTMLFormControlsCollection implements HTMLFormControlsCollection (supplemental)
external inline namedItem : (this: htmlFormControlsCollection, name: string) -> dom any /* former ::object */
{ inline "#1.namedItem(#2)" }

// HTMLFormControlsCollection extends HTMLCollection
external inline htmlCollection : (htmlFormControlsCollection) -> htmlCollection // upcasting to extended type
{ inline "#1" }
// HTMLFormControlsCollection implements in extension HTMLCollection (overloading)
external inline length : (this: htmlFormControlsCollection) -> dom uint32
{ inline "#1.length" }
external inline item : (this: htmlFormControlsCollection, index: uint32) -> dom element
{ inline "#1.item(#2)" }

external inline namedItem : (this: htmlFormControlsCollection, name: string) -> dom any /* former ::object */
{ inline "#1.namedItem(#2)" }

