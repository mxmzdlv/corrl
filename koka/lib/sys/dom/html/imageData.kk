public module sys/dom/html/imageData

// Interface ImageData (generated by esidl 0.2.0).

import sys/dom/types

/* safe and unsafe conversion from all types including `any */
external inline maybeImageData  : forall<a> (a) -> maybe<imageData>
{ inline "(#1.toString()==='[object ImageData]'?std_core.Just(#1):std_core.Nothing)" }
external inline toImageData : forall<a> (a) -> exn imageData
{ inline "(#1.toString()==='[object ImageData]'?#1:std_core.error('toImageData: cast failed'))" }


// ImageData implements ImageData (supplemental)
external inline width : (this: imageData) -> dom uint32
{ inline "#1.width" }
external inline height : (this: imageData) -> dom uint32
{ inline "#1.height" }
external inline data : (this: imageData) -> dom uint8Array
{ inline "#1.data" }

