# Keep runtime annotations used by Room and kotlinx.serialization while allowing
# R8 to optimize implementation details in a signed release build.
-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations,AnnotationDefault
