# ``NodeGraphCore``

Models, execution, undo and serialization for node graphs, with no UI and no domain knowledge.

## Overview

A ``Graph`` holds nodes, ports and links. Every change goes through a command so that undo, redo and a future server change log stay correct. Node types, port types and value types are registered by packs, never hard-coded here, so the same core serves robotics, video editing and anything else.

Core is pure Swift and builds on Linux.

## Topics

### Essentials

- ``Graph``
- ``Node``
- ``Link``
- ``GraphValue``

### Editing

- ``GraphEditor``
- ``GraphHistory``

### Running

- ``GraphRunner``

### Extending

- ``NodePack``
- ``NodeRegistry``
- ``TypeRegistry``
- ``NodeDefinition``

### Saving

- ``GraphDocument``
