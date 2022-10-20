//#define NUM_TRANSDUCERS 1024		//We will make this a compile-time argument.
#define NUM_TRANSDUCERS_PER_GROUP 256 //TODO: Make this an argument.
#define MAX_POINTS_PER_GEOMETRY 32
#define NUM_ITERATIONS 20
#define PI 3.14159265359f
#define K 726.379761f


__constant sampler_t sampleVolTexture = CLK_NORMALIZED_COORDS_TRUE | 
CLK_ADDRESS_NONE | CLK_FILTER_NEAREST; 

__constant sampler_t sampleDirTexture = CLK_NORMALIZED_COORDS_TRUE | 
CLK_ADDRESS_NONE | CLK_FILTER_NEAREST; 

__kernel void computeFandB(global float4* transducerPositionsWorld,
	global float4* positions,
	global float4* matrixG0,
	global float4* matrixGN,
	read_only int pointsPerGeometry,
	read_only int numGeometries,
	read_only image2d_t directivity_cos_alpha,
	global float2* pointHologram,
	global float2* unitaryPointHologram
) {
	//0. Get indexes:
	int t_x = get_global_id(0);		//coord x of the transducer		
	int group = t_x / NUM_TRANSDUCERS_PER_GROUP;			//Get our board from our ID (board 1 iff id>255)
	int t_offset = t_x;
	int point_ = get_global_id(2);				//point hologram to create
	uint offset = get_global_size(0)* point_;	//Offset where we write the hologram
	uint CUR_NUM_TRANSDUCERS = get_global_size(0);

	//1. Let's work out the matrix we need to apply:
	int geometry = point_ / pointsPerGeometry;		//Work out cour geometry number
	int pointNumber = point_ % pointsPerGeometry;
	float interpolationRatio = (1.0f*geometry) / numGeometries; // (fmax(numGeometries - 1.0f, 1.0f));//Avoid division by zero if numGeometries=1;
	__local float4 ourMatrix[4];					//Common buffer to store our local transformation matrix (interpolated from extremes)
	if (t_x < 4) {
		ourMatrix[t_x] = (1-interpolationRatio) * matrixG0[pointNumber * 4 + t_x] + (interpolationRatio)*matrixGN[pointNumber * 4 + t_x];
	}
	barrier(CLK_LOCAL_MEM_FENCE);
	
	//STAGE 1: Build point hologram 
	//A. Get position of point in world coordinates (using the matrix we computed):
	float4 local_p_pos = positions[point_];					//Local position in the geometry is read from the descriptor
	float4 p_pos = (float4)(dot(ourMatrix[0], local_p_pos)	//Absolute position computed by multiplying with our matrix.
		, dot(ourMatrix[1], local_p_pos)
		, dot(ourMatrix[2], local_p_pos)
		, dot(ourMatrix[3], local_p_pos));

	//B. Get the position of our transducer 
	float4 t_pos = transducerPositionsWorld[t_offset];
	float4 transducerToPoint = p_pos - t_pos; 
	float distance = native_sqrt(transducerToPoint.x*transducerToPoint.x + transducerToPoint.y*transducerToPoint.y + transducerToPoint.z*transducerToPoint.z);
	//This computes cos_alpha ASSUMING transducer normal is (0,0,1); Divide by dist to make unitary vector (normalise). 
	float cos_alpha = fabs((float)(transducerToPoint.z / distance));
	
															
																	
	//c. Sample 1D texture: 
	float4 amplitude= read_imagef(directivity_cos_alpha, sampleDirTexture, (float2)(cos_alpha, 0.5f))/distance;
	float Re = amplitude.x*native_cos(-K*distance);
	float Im = amplitude.x*native_sin(-K*distance);
	//STAGE 2: Building the holograms:
	//a. compute normal propagator (point hologram):	
	pointHologram[offset + t_offset] = (float2)(Re , Im );
	//b. compute "normalised" point hologram (reconstruction amplitude exactly = one Pa)
	float amplitude_t_x = Re * Re + Im * Im;
	__local float amplitude_Group0[NUM_TRANSDUCERS];
	__local float amplitude_Group1[NUM_TRANSDUCERS];
	amplitude_Group0[t_x] = (1 - group)*amplitude_t_x;
	amplitude_Group1[t_x] = group*amplitude_t_x;
	barrier(CLK_LOCAL_MEM_FENCE);
	//a. Reduce (add all elements in hologram)
	for (int i = CUR_NUM_TRANSDUCERS/2; i > 0; i >>= 1) {
		if (t_x < i) {
			amplitude_Group0[t_x] += amplitude_Group0[t_x + i];
			amplitude_Group1[t_x] += amplitude_Group1[t_x + i];
		}
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	//c. Normalise (divide by sumation of contributions squared... see Long et al) 
	//   Each transducer only takes into account the amplitude contributed by member in 
	// its group (top group/bottom group). 
	// Each group is normalized to 0.5, so both groups together still provide 1Pa.
	Re /= 2*((1-group)*amplitude_Group0[0]+group*amplitude_Group1[0]); 
	Im /= 2*((1-group)*amplitude_Group0[0]+group*amplitude_Group1[0]);
	unitaryPointHologram[offset + t_offset] = (float2)(Re, Im);		//Re	
}

__kernel void solvePhases_GS(global float2* points_Re_Im,
	global float2* points_Re_Im_solution,
	read_only int num_geometries, 
	global float2* R,
	global float* amplitudesPerPoint,
	global float* estimatedAmplitudesPerPoint,
	global float* finalAmplitudeCorrection
) {
	int numPoints = get_global_size(0);
	int j = get_local_id(0);
	for (int geometry = 0; geometry < num_geometries; geometry++) {
		int geometry_prev = ((geometry - 1)%num_geometries +num_geometries)%num_geometries; //modulus of a negative number is a bitch...	
		int offset_R = numPoints * numPoints*geometry;
		float2 row_j[MAX_POINTS_PER_GEOMETRY];
		__local float2 _localPoints1[MAX_POINTS_PER_GEOMETRY];
		//0. Copy points, target amplitudes and row to local buffers and synchronise (Note this copies the two elements in points_Re_Im (_localPoints is float2)
		//0.a. Copying elements of matrix R and target amplitudes
		for (int i = 0; i < numPoints; i++)
			row_j[i] = (float2)(R[offset_R + (j*numPoints + i)].x, -R[offset_R + (j*numPoints + i)].y);
		//0.b. Copying points (amplitude of initial guess =1, so we multiply by target amplitude)
		_localPoints1[j] = amplitudesPerPoint[numPoints*geometry + j] * points_Re_Im[geometry_prev*MAX_POINTS_PER_GEOMETRY + j];
		barrier(CLK_LOCAL_MEM_FENCE);//We wait so that all local points are ready.

		//1. Compute our phase update (only one iteration)
		float2 iteration_j = (float2)(0, 0);
		//a. Multiply _localPoints1 by row and store into points_Re_Im (global, normalize) and points_Re_Im_solution (no normalize)
		for (int j1 = 0; j1 < numPoints; j1++) {
			float2 result_j1=(float2)(	 row_j[j1].x*_localPoints1[j1].x - row_j[j1].y*_localPoints1[j1].y
										,row_j[j1].x*_localPoints1[j1].y + row_j[j1].y*_localPoints1[j1].x);
			iteration_j += result_j1;
		}
		//b. Store results
		float amplitude = native_sqrt(iteration_j.x*iteration_j.x + iteration_j.y*iteration_j.y);
		iteration_j /= amplitude;
		points_Re_Im[j + numPoints * geometry] = iteration_j;
		points_Re_Im_solution[j + numPoints * geometry] = amplitudesPerPoint[numPoints*geometry + j] *iteration_j;
		barrier(CLK_LOCAL_MEM_FENCE);	//Wait, as the next iteration will need all point from last iteratio to be ready	
		//NOTES: Features removed:
		//No constraint (we do not force phase of point[0] = 0 --> I think we do not need this any more
		//No per-point amplitude corrections (based on stimated amplitudes) --> This could be interesting (Giorgos)
		//No global correction (this had been disabled in prior versions anyways). 
		
	}
}

__kernel void computeActivation(int numPoints,
	global float2* holograms,
	global float2* points_Re_Im,		//Points representing target amplitude and phase.
	global float* finalAmplitudeCorrection,
	global float* finalHologram_Phases, //this contains the final phases to send to the array (with lev signature, phase only, A=1)
	global float* finalHologram_Amplitudes, //this contains the final phases to send to the array (with lev signature, phase only, A=1)
	global float2* finalHologram_ReIm)   //this contains the "focussing hologram" (Re and Im parts, no lev signature)
{

	//get indexes:
	int x = get_global_id(0);
	//int y = get_global_id(1);
	int g = get_global_id(2);
	const int hologramSize =get_global_size(0);
	int group = x / NUM_TRANSDUCERS_PER_GROUP;			//Get our board from our ID (board 1 iff id>255)
	//Copy points to local array
	__local float2 _localPoints[MAX_POINTS_PER_GEOMETRY];
	if (x < numPoints )
		_localPoints[x] = points_Re_Im[x + g * numPoints];
	barrier(CLK_LOCAL_MEM_FENCE);
	//Sum all pixels (x,y), applying the phase of each point to each hologram
	float2 sum_H_x_y = (float2)(0, 0);
	int offset = x + g * hologramSize*numPoints;									//Position of pixel (x,y) into each hologram
	for (int p = 0; p < numPoints; p++, offset += hologramSize) {
		float2 hologPixel = holograms[offset];													 //Hologram for a zero phase
		sum_H_x_y += (float2)((hologPixel.x*_localPoints[p].x - hologPixel.y*_localPoints[p].y)
			, (hologPixel.x*_localPoints[p].y + hologPixel.y*_localPoints[p].x));//Hologram adjusted to selected point phase
	}
	//Cap amplitude to maximum transducer power
	float amplitude = native_sqrt(sum_H_x_y.x*sum_H_x_y.x + sum_H_x_y.y*sum_H_x_y.y);// *finalAmplitudeCorrection[g];
	float amplitudeCapped = fmin(amplitude, 1);
	
	//Write focusing hologram (no lev signature)
	finalHologram_ReIm[x + g * hologramSize] = sum_H_x_y * amplitudeCapped / amplitude;
	
	//Write final phases: (Adding Lev. signature)
	finalHologram_Phases[x  + g * hologramSize] = (atan2(sum_H_x_y.y, sum_H_x_y.x)+PI*group);
	finalHologram_Amplitudes[x  + g * hologramSize] = amplitudeCapped;
	
}

__kernel void discretise(int numDiscreteLevels,
	global float* phasesDataBuffer,
	global float* amplitudesDataBuffer,
	float phaseOnly,
	global float* phaseAdjustPerTransducerNumber,
	global unsigned char* transducerNumberToPIN_ID,
	global unsigned char* messages) {
	//1. Get transducer coordinates and geometry number
	int x = get_global_id(0);	
	int y = get_global_id(1);//useless
	int g = get_global_id(2);
	const int hologramSize = get_global_size(0);
	//2. Map transducer to  message parameters (message number, PIN index, correction , etc):
	int messageNumber= ( x>>8);
	unsigned char PIN_index = transducerNumberToPIN_ID[x];//PIN index in its local board (256 elements)
	int posInMessage = 512*messageNumber + PIN_index ;//Pos in the global message (for all boards)
	unsigned char firstCharFlag = (unsigned char)(PIN_index == 0);
	float phaseHardwareCorrection = phaseAdjustPerTransducerNumber[x];
	
	//3. Read input data: 
	float targetAmplitude = amplitudesDataBuffer[hologramSize * g + x];
	float targetPhase =		phasesDataBuffer[hologramSize * g + x];
	//3.A. Discretise Amplitude: If phase only, set duty to 50% (unless targetAmplitude is zero (i.e. smaller than first discretized level))
	//							Otherwise, compute duty cycle from arcsin(amplitude*PI) as from nature paper).	
	float targetDutyCycle = 0.5f*phaseOnly*(float)(targetAmplitude) 
		+ (1 - phaseOnly)*asinpi(targetAmplitude);		//Compute duty cycle, given transducer response.
	unsigned char discretisedA = (unsigned char)(numDiscreteLevels * targetDutyCycle);
	//When duty cycle (amplitude) is not 50%, we need to make slight adjustments to phase also:
	float phaseCorrection = (2 * PI*((numDiscreteLevels / 2 - discretisedA) / 2)) / numDiscreteLevels;
	
	//3.B. Discretise Phase: (we add 2PI to make sure fmod will return a positive phase value.
	float correctedPhase = fmod(targetPhase - phaseHardwareCorrection + phaseCorrection + 2*PI
		, 2 * PI);
	//correctedPhase += (float)(correctedPhase < 0) * 2 * PI;//Add 2PI if negative (without using branches...)--> NOT NEEDED ANY MORE (We add 2PI always)
	unsigned char discretisedPhase = correctedPhase * numDiscreteLevels / (2 * PI);
	//4. Store in the buffer (each message has 256 phases and 256 amplitudes ->512 elements)
	messages[g * hologramSize * 2 + posInMessage ] = discretisedPhase +firstCharFlag * numDiscreteLevels;
	messages[g * hologramSize * 2 + posInMessage +256] =discretisedA;

	//DEBUG: Phase only 
	/*unsigned char discretisedA = numDiscreteLevels / 2;
	float correctedPhase = fmod(targetPhase - phaseHardwareCorrection + 2 * PI, 2 * PI);
	float negativePhaseRadians = (float)(correctedPhase< 0);
	unsigned char discretisedPhase = (unsigned char) (correctedPhase * numDiscreteLevels / (2 * PI));
	*/
	//END DEBUG	
	//DEBUG: Check mappings, phase corrections...
	//messages[g * hologramSize * 2 + posInMessage ] = discretisedPhase +firstCharFlag * numDiscreteLevels;;
	//messages[g * hologramSize * 2 + posInMessage +256] =discretisedA;
	//messages[g * hologramSize * 2 + x ] = PIN_index;
	//messages[g * hologramSize * 2 + hologramSize + x ] = (unsigned char) negativePhaseRadians ;
	////messages[g * hologramSize * 2 + hologramSize + x] =(unsigned char)(phaseHardwareCorrection*180/(PI));	
	//messages[g * hologramSize * 2 + hologramSize + x] = ( char)(phaseAdjustPerTransducerNumber[x]*180/(PI));
	//messages[g * hologramSize * 2 + hologramSize + x] = messageNumber;
	////messages[g * hologramSize * 2 + x ] = x;
	////messages[g * hologramSize * 2 + hologramSize + x ] = g;	
	//END DEBUG
}


__kernel void discretiseTopBottom(int numDiscreteLevels,
	global float* phasesDataBuffer,
	global float* amplitudesDataBuffer,
	float phaseOnly,
	global float* phaseAdjustPerTransducerNumber,
	global unsigned char* transducerNumberToPIN_ID,
	global unsigned char* messagesTop,
	global unsigned char* messagesBottom) {
	//1. Get transducer coordinates and geometry number
	int x_global = get_global_id(0);
	unsigned char topArray = (unsigned char)(x_global >= 16);
	int x = x_global - 16 * topArray;
	int y = get_global_id(1);
	int g = get_global_id(2);
	const int hologramHeight = get_global_size(1);
	const int hologramWidth = get_global_size(0) / 2;	//The holograms are split, half written to messagesTop, and half to messagesBottom...
	const int hologramSize = hologramHeight * hologramWidth;
	//2. Map transducer to  PIN index:
	int indexInDataBuffers = hologramWidth * y + x + topArray * 256;
	unsigned char PIN_index = transducerNumberToPIN_ID[indexInDataBuffers];
	//3. Read input data: 
	float targetAmplitude = amplitudesDataBuffer[hologramSize * 2 * g + indexInDataBuffers];
	float targetPhase = phasesDataBuffer[hologramSize * 2 * g + indexInDataBuffers];
	//3.A. Discretise Amplitude: 
	float targetDutyCycle = 0.5f*phaseOnly + (1 - phaseOnly)*asinpi(targetAmplitude);		//Compute duty cycle, given transducer response.

	unsigned char discretisedA = (unsigned char)(numDiscreteLevels * targetDutyCycle);
	float phaseCorrection = (2 * PI*((numDiscreteLevels / 2 - discretisedA) / 2)) / numDiscreteLevels;

	//3.B. Discretise Phase: 
	float correctedPhase = fmod(targetPhase - phaseAdjustPerTransducerNumber[indexInDataBuffers] + phaseCorrection
		, 2 * PI);
	correctedPhase += (float)(correctedPhase < 0) * 2 * PI;//Add 2PI if negative (without using branches...)
	unsigned char discretisedPhase = correctedPhase * numDiscreteLevels / (2 * PI);
	//3.C. Signal if transducer is (0,0)
	unsigned char firstCharFlag = (unsigned char)(PIN_index == 0);

	//4. Store in the right buffer
	global unsigned char* buffers[2];
	buffers[1] = messagesTop;
	buffers[0] = messagesBottom;
	//Normal case
	buffers[topArray][PIN_index + g * hologramSize * 2] = discretisedPhase +firstCharFlag * numDiscreteLevels;
	buffers[topArray][PIN_index + g*hologramSize * 2 +256] =discretisedA;
	//buffers[topArray][PIN_index + g * hologramSize * 2] = indexInDataBuffers;
	//buffers[topArray][PIN_index + g*hologramSize * 2 +256] =g;
	//buffers[topArray][PIN_index + g * hologramSize * 2] = x_global;
	//buffers[topArray][PIN_index + g*hologramSize * 2 +256] =indexInDataBuffers;

}